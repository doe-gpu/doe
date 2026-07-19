// TSIR canonical JSON serialization and digest computation.
//
// Canonical form rules:
//   - Object keys emitted in lexicographic byte order of the camelCase
//     JSON field name (matching `config/doe-tsir-semantic.schema.json`).
//   - No whitespace between tokens.
//   - Numbers emitted in minimal base-10 form.
//   - Strings UTF-8, escape set restricted to \" \\ \n \r \t \uXXXX.
//   - Enums emitted as their snake_case tag name quoted.
//   - Digests (`[32]u8`) emitted as 64-char lowercase hex strings.
//
// SHA-256 over the canonical UTF-8 bytes yields the 32-byte digest.
//
// Semantic canonicalization walks every field of every nested TSIR
// type and emits it in the declared order (lex-sorted keys, canonical
// JSON form per the grammar at the top of this file). Realization
// canonicalization has the same treatment — a dedicated walker covers
// tile factors, PE grid, residency, collectives, reductions, target
// descriptor hash, and emitter params. Both produce stable digests
// under content-equivalent TSIR inputs.

const std = @import("std");
const schema = @import("schema.zig");

pub const DigestError = error{
    OutOfMemory,
    InvalidSemantic,
    InvalidRealization,
};

/// Compute the three digests for a (semantic, realization) pair.
pub fn compute(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    realization: schema.Realization,
    emitter_version: []const u8,
) DigestError!schema.Digests {
    return computeWithEmitterDigest(
        allocator,
        semantic,
        realization,
        sha256(emitter_version),
    );
}

/// Compute split TSIR digests when the caller already has a content-addressed
/// emitter identity, such as `emit_csl.emitterCodeDigest()`.
pub fn computeWithEmitterDigest(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    realization: schema.Realization,
    emitter_digest: [32]u8,
) DigestError!schema.Digests {
    const semantic_bytes = try canonicalizeSemantic(allocator, semantic);
    defer allocator.free(semantic_bytes);
    const realization_bytes = try canonicalizeRealization(allocator, realization);
    defer allocator.free(realization_bytes);

    var digests: schema.Digests = undefined;
    digests.semantic = sha256(semantic_bytes);
    digests.realization = sha256(realization_bytes);
    digests.emitter = emitter_digest;
    return digests;
}

fn sha256(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

fn emitString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) DigestError!void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var tmp: [6]u8 = undefined;
                const slice = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch return error.InvalidSemantic;
                try buf.appendSlice(allocator, slice);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn emitU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) DigestError!void {
    var tmp: [12]u8 = undefined;
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return error.InvalidSemantic;
    try buf.appendSlice(allocator, slice);
}

fn emitU64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) DigestError!void {
    var tmp: [22]u8 = undefined;
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return error.InvalidSemantic;
    try buf.appendSlice(allocator, slice);
}

fn emitI32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i32) DigestError!void {
    var tmp: [12]u8 = undefined;
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return error.InvalidSemantic;
    try buf.appendSlice(allocator, slice);
}

fn emitF64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: f64) DigestError!void {
    if (std.math.isNan(v) or std.math.isInf(v)) return error.InvalidSemantic;
    var tmp: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return error.InvalidSemantic;
    try buf.appendSlice(allocator, slice);
}

fn emitOptionalF64(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: ?f64,
) DigestError!void {
    if (value) |v| {
        try emitF64(buf, allocator, v);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn emitBool(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: bool) DigestError!void {
    try buf.appendSlice(allocator, if (v) "true" else "false");
}

fn emitHexDigest(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, digest: [32]u8) DigestError!void {
    try buf.append(allocator, '"');
    var tmp: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        const slice = std.fmt.bufPrint(tmp[i * 2 ..][0..2], "{x:0>2}", .{b}) catch return error.InvalidSemantic;
        _ = slice;
    }
    try buf.appendSlice(allocator, tmp[0..]);
    try buf.append(allocator, '"');
}

fn emitKey(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8) DigestError!void {
    try emitString(buf, allocator, key);
    try buf.append(allocator, ':');
}

fn canonicalizeSemantic(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
) DigestError![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try emitSemantic(&buf, allocator, semantic);
    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn emitSemantic(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.Semantic,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex order: contractVersion, frontendVersion, functions, rejections.
    try emitKey(buf, allocator, "contractVersion");
    try emitU32(buf, allocator, value.contract_version);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "frontendVersion");
    try emitString(buf, allocator, value.frontend_version);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "functions");
    try buf.append(allocator, '[');
    for (value.functions, 0..) |f, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitSemanticFunction(buf, allocator, f);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "rejections");
    try buf.append(allocator, '[');
    for (value.rejections, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitRejectionEntry(buf, allocator, r);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, '}');
}

fn emitSemanticFunction(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.SemanticFunction,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: axes, bindings, body, collectives, familyHint, name, reductions, sourceDigest.
    try emitKey(buf, allocator, "axes");
    try buf.append(allocator, '[');
    for (value.axes, 0..) |a, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitIterationAxis(buf, allocator, a);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "bindings");
    try buf.append(allocator, '[');
    for (value.bindings, 0..) |b, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitBufferBinding(buf, allocator, b);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "body");
    try emitSemanticBody(buf, allocator, value.body);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "collectives");
    try buf.append(allocator, '[');
    for (value.collectives, 0..) |c, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitCollectiveSemanticNode(buf, allocator, c);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "familyHint");
    try emitString(buf, allocator, @tagName(value.family_hint));
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "name");
    try emitString(buf, allocator, value.name);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "reductions");
    try buf.append(allocator, '[');
    for (value.reductions, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitReductionRegion(buf, allocator, r);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "sourceDigest");
    try emitHexDigest(buf, allocator, value.source_digest);
    try buf.append(allocator, '}');
}

fn emitSemanticBody(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.SemanticBody,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: axisRoles, bindingRoles, op, rmsNorm.
    try emitKey(buf, allocator, "axisRoles");
    try buf.append(allocator, '[');
    for (value.axis_roles, 0..) |role, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitSemanticBodyAxis(buf, allocator, role);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "bindingRoles");
    try buf.append(allocator, '[');
    for (value.binding_roles, 0..) |role, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitSemanticBodyBinding(buf, allocator, role);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "op");
    try emitString(buf, allocator, @tagName(value.op));
    if (value.rms_norm) |rms_norm| {
        try buf.append(allocator, ',');
        try emitKey(buf, allocator, "rmsNorm");
        try emitRmsNormBody(buf, allocator, rms_norm);
    }
    try buf.append(allocator, '}');
}

fn emitSemanticBodyBinding(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.SemanticBodyBinding,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: bindingIndex, role.
    try emitKey(buf, allocator, "bindingIndex");
    try emitU32(buf, allocator, value.binding_index);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "role");
    try emitString(buf, allocator, @tagName(value.role));
    try buf.append(allocator, '}');
}

fn emitSemanticBodyAxis(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.SemanticBodyAxis,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: axisIndex, role.
    try emitKey(buf, allocator, "axisIndex");
    try emitU32(buf, allocator, value.axis_index);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "role");
    try emitString(buf, allocator, @tagName(value.role));
    try buf.append(allocator, '}');
}

fn emitRmsNormBody(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.RmsNormBody,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: epsilon, formula, hiddenExtentAxis, reductionTarget.
    try emitKey(buf, allocator, "epsilon");
    try emitRmsNormEpsilon(buf, allocator, value.epsilon);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "formula");
    try emitString(buf, allocator, @tagName(value.formula));
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "hiddenExtentAxis");
    try emitU32(buf, allocator, value.hidden_extent_axis);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "reductionTarget");
    try emitString(buf, allocator, @tagName(value.reduction_target));
    try buf.append(allocator, '}');
}

fn emitRmsNormEpsilon(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.RmsNormEpsilon,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: bindingIndex, byteOffset, literalF32, path, source.
    try emitKey(buf, allocator, "bindingIndex");
    try emitOptionalU32(buf, allocator, value.binding_index);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "byteOffset");
    try emitOptionalU32(buf, allocator, value.byte_offset);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "literalF32");
    try emitOptionalF64(buf, allocator, value.literal_f32);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "path");
    try emitString(buf, allocator, value.path);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "source");
    try emitString(buf, allocator, @tagName(value.source));
    try buf.append(allocator, '}');
}

fn emitIterationAxis(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.IterationAxis,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: lowerBound, name, step, upperBound.
    try emitKey(buf, allocator, "lowerBound");
    try emitString(buf, allocator, value.lower_bound);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "name");
    try emitString(buf, allocator, value.name);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "step");
    try emitString(buf, allocator, value.step);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "upperBound");
    try emitString(buf, allocator, value.upper_bound);
    try buf.append(allocator, '}');
}

fn emitBufferBinding(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.BufferBinding,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: binding, elem, group, logicalShape, name, readWrite.
    try emitKey(buf, allocator, "binding");
    try emitU32(buf, allocator, value.binding);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "elem");
    try emitString(buf, allocator, @tagName(value.elem));
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "group");
    try emitU32(buf, allocator, value.group);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "logicalShape");
    try buf.append(allocator, '[');
    for (value.logical_shape, 0..) |d, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitU64(buf, allocator, d);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "name");
    try emitString(buf, allocator, value.name);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "readWrite");
    try emitBool(buf, allocator, value.read_write);
    try buf.append(allocator, '}');
}

fn emitReductionRegion(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.ReductionRegion,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: axis, contract, op, targetBinding.
    try emitKey(buf, allocator, "axis");
    try emitU32(buf, allocator, value.axis);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "contract");
    try emitNumericalContract(buf, allocator, value.contract);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "op");
    try emitString(buf, allocator, @tagName(value.op));
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "targetBinding");
    try emitU32(buf, allocator, value.target_binding);
    try buf.append(allocator, '}');
}

fn emitNumericalContract(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.NumericalContract,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: accumulation, associativity, nanInf.
    try emitKey(buf, allocator, "accumulation");
    try emitString(buf, allocator, @tagName(value.accumulation));
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "associativity");
    try emitString(buf, allocator, @tagName(value.associativity));
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "nanInf");
    try emitString(buf, allocator, @tagName(value.nan_inf));
    try buf.append(allocator, '}');
}

fn emitCollectiveSemanticNode(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.CollectiveSemanticNode,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: axis, dtype, exactness, kind.
    try emitKey(buf, allocator, "axis");
    try emitI32(buf, allocator, value.axis);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "dtype");
    try emitString(buf, allocator, @tagName(value.dtype));
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "exactness");
    try emitExactness(buf, allocator, value.exactness);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "kind");
    try emitString(buf, allocator, @tagName(value.kind));
    try buf.append(allocator, '}');
}

fn emitExactness(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.Exactness,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: algorithmExactInvariants, class, toleranceEpsilon, toleranceMetric.
    try emitKey(buf, allocator, "algorithmExactInvariants");
    try buf.append(allocator, '[');
    for (value.algorithm_exact_invariants, 0..) |inv, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitString(buf, allocator, @tagName(inv));
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "class");
    try emitString(buf, allocator, @tagName(value.class));
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "toleranceEpsilon");
    try emitF64(buf, allocator, value.tolerance_epsilon);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "toleranceMetric");
    try emitString(buf, allocator, value.tolerance_metric);
    try buf.append(allocator, '}');
}

fn emitRejectionEntry(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.RejectionEntry,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: detail, nodePath, reason.
    try emitKey(buf, allocator, "detail");
    try emitString(buf, allocator, value.detail);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "nodePath");
    try emitString(buf, allocator, value.node_path);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "reason");
    try emitString(buf, allocator, @tagName(value.reason));
    try buf.append(allocator, '}');
}

fn canonicalizeRealization(
    allocator: std.mem.Allocator,
    realization: schema.Realization,
) DigestError![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try emitRealization(&buf, allocator, realization);
    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn emitRealization(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.Realization,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: contractVersion, emitterDigest, functions, rejections.
    try emitKey(buf, allocator, "contractVersion");
    try emitU32(buf, allocator, value.contract_version);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "emitterDigest");
    try emitHexDigest(buf, allocator, value.emitter_digest);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "functions");
    try buf.append(allocator, '[');
    for (value.functions, 0..) |f, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitRealizationFunction(buf, allocator, f);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "rejections");
    try buf.append(allocator, '[');
    for (value.rejections, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitRejectionEntry(buf, allocator, r);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, '}');
}

fn emitRealizationFunction(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.RealizationFunction,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: collectives, emitterParamsJson, peGrid, reductions, residency,
    // semanticIndex, targetDescriptorHash, tiles.
    try emitKey(buf, allocator, "collectives");
    try buf.append(allocator, '[');
    for (value.collectives, 0..) |c, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitCollectiveRealizationNode(buf, allocator, c);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "emitterParamsJson");
    try emitString(buf, allocator, value.emitter_params_json);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "peGrid");
    try emitPEGridShape(buf, allocator, value.pe_grid);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "reductions");
    try buf.append(allocator, '[');
    for (value.reductions, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitReductionRealizationNode(buf, allocator, r);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "residency");
    try buf.append(allocator, '[');
    for (value.residency, 0..) |d, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitResidencyDecision(buf, allocator, d);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "semanticIndex");
    try emitU32(buf, allocator, value.semantic_index);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "targetDescriptorHash");
    try emitHexDigest(buf, allocator, value.target_descriptor_hash);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "tiles");
    try emitTileFactors(buf, allocator, value.tiles);
    try buf.append(allocator, '}');
}

fn emitTileFactors(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.TileFactors,
) DigestError!void {
    try buf.append(allocator, '{');
    try emitKey(buf, allocator, "perAxis");
    try buf.append(allocator, '[');
    for (value.per_axis, 0..) |d, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitU32(buf, allocator, d);
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, '}');
}

fn emitPEGridShape(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.PEGridShape,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: height, width.
    try emitKey(buf, allocator, "height");
    try emitU32(buf, allocator, value.height);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "width");
    try emitU32(buf, allocator, value.width);
    try buf.append(allocator, '}');
}

fn emitResidencyDecision(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.ResidencyDecision,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: axis, bindingIndex, chunkBytes, class, fabricColor, shards.
    try emitKey(buf, allocator, "axis");
    try emitOptionalU32(buf, allocator, value.axis);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "bindingIndex");
    try emitU32(buf, allocator, value.binding_index);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "chunkBytes");
    try emitOptionalU64(buf, allocator, value.chunk_bytes);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "class");
    try emitString(buf, allocator, @tagName(value.class));
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "fabricColor");
    try emitOptionalU32(buf, allocator, value.fabric_color);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "shards");
    try emitOptionalU32(buf, allocator, value.shards);
    try buf.append(allocator, '}');
}

fn emitCollectiveRealizationNode(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.CollectiveRealizationNode,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: fabricColor, groupSize, semanticIndex, treeShape.
    try emitKey(buf, allocator, "fabricColor");
    try emitOptionalU32(buf, allocator, value.fabric_color);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "groupSize");
    try emitU32(buf, allocator, value.group_size);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "semanticIndex");
    try emitU32(buf, allocator, value.semantic_index);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "treeShape");
    try emitString(buf, allocator, @tagName(value.tree_shape));
    try buf.append(allocator, '}');
}

fn emitReductionRealizationNode(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.ReductionRealizationNode,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex: semanticIndex, treeShape.
    try emitKey(buf, allocator, "semanticIndex");
    try emitU32(buf, allocator, value.semantic_index);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "treeShape");
    try emitString(buf, allocator, @tagName(value.tree_shape));
    try buf.append(allocator, '}');
}

fn emitOptionalU32(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: ?u32,
) DigestError!void {
    if (value) |v| {
        try emitU32(buf, allocator, v);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

fn emitOptionalU64(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: ?u64,
) DigestError!void {
    if (value) |v| {
        try emitU64(buf, allocator, v);
    } else {
        try buf.appendSlice(allocator, "null");
    }
}

pub fn canonicalizeManifestLoweringEntry(
    allocator: std.mem.Allocator,
    entry: schema.ManifestLoweringEntry,
) DigestError![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try emitManifestLoweringEntry(&buf, allocator, entry);
    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

pub fn manifestLoweringEntryDigest(
    allocator: std.mem.Allocator,
    entry: schema.ManifestLoweringEntry,
) DigestError![32]u8 {
    const bytes = try canonicalizeManifestLoweringEntry(allocator, entry);
    defer allocator.free(bytes);
    return sha256(bytes);
}

fn emitManifestLoweringEntry(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: schema.ManifestLoweringEntry,
) DigestError!void {
    try buf.append(allocator, '{');
    // Lex order of camelCase keys:
    // backend, compilerVersion, emitterDigest, exactness, frontendVersion,
    // kernelRef, rejectionReasons, targetDescriptorCorrectnessHash,
    // tsirRealizationDigest, tsirSemanticDigest.
    try emitKey(buf, allocator, "backend");
    try emitString(buf, allocator, value.backend);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "compilerVersion");
    try emitString(buf, allocator, value.compiler_version);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "emitterDigest");
    try emitHexDigest(buf, allocator, value.emitter_digest);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "exactness");
    try emitExactness(buf, allocator, value.exactness);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "frontendVersion");
    try emitString(buf, allocator, value.frontend_version);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "kernelRef");
    try emitString(buf, allocator, value.kernel_ref);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "rejectionReasons");
    try buf.append(allocator, '[');
    for (value.rejection_reasons, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try emitString(buf, allocator, @tagName(r));
    }
    try buf.append(allocator, ']');
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "targetDescriptorCorrectnessHash");
    try emitHexDigest(buf, allocator, value.target_descriptor_correctness_hash);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "tsirRealizationDigest");
    try emitHexDigest(buf, allocator, value.tsir_realization_digest);
    try buf.append(allocator, ',');
    try emitKey(buf, allocator, "tsirSemanticDigest");
    try emitHexDigest(buf, allocator, value.tsir_semantic_digest);
    try buf.append(allocator, '}');
}

test "empty semantic canonicalizes to the expected JSON bytes" {
    const allocator = std.testing.allocator;
    const semantic = schema.Semantic{
        .functions = &.{},
        .rejections = &.{},
    };
    const bytes = try canonicalizeSemantic(allocator, semantic);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"contractVersion\":1,\"frontendVersion\":\"\",\"functions\":[],\"rejections\":[]}",
        bytes,
    );
}

test "semantic with one function canonicalizes with lex-sorted keys" {
    const allocator = std.testing.allocator;
    const shape = [_]u64{4};
    const bindings = [_]schema.BufferBinding{
        .{
            .name = "in",
            .group = 0,
            .binding = 0,
            .logical_shape = &shape,
            .elem = .f32,
            .read_write = false,
        },
        .{
            .name = "out",
            .group = 0,
            .binding = 1,
            .logical_shape = &shape,
            .elem = .f32,
            .read_write = true,
        },
    };
    const axes = [_]schema.IterationAxis{
        .{ .name = "i", .lower_bound = "0", .upper_bound = "4", .step = "1" },
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
    const semantic = schema.Semantic{
        .frontend_version = "v1",
        .functions = &funcs,
        .rejections = &.{},
    };

    const bytes = try canonicalizeSemantic(allocator, semantic);
    defer allocator.free(bytes);

    const expected =
        "{\"contractVersion\":1," ++
        "\"frontendVersion\":\"v1\"," ++
        "\"functions\":[" ++
        "{\"axes\":[" ++
        "{\"lowerBound\":\"0\",\"name\":\"i\",\"step\":\"1\",\"upperBound\":\"4\"}" ++
        "]," ++
        "\"bindings\":[" ++
        "{\"binding\":0,\"elem\":\"f32\",\"group\":0,\"logicalShape\":[4],\"name\":\"in\",\"readWrite\":false}," ++
        "{\"binding\":1,\"elem\":\"f32\",\"group\":0,\"logicalShape\":[4],\"name\":\"out\",\"readWrite\":true}" ++
        "]," ++
        "\"body\":{\"axisRoles\":[],\"bindingRoles\":[],\"op\":\"unknown\"}," ++
        "\"collectives\":[]," ++
        "\"familyHint\":\"elementwise\"," ++
        "\"name\":\"identity\"," ++
        "\"reductions\":[]," ++
        "\"sourceDigest\":\"0000000000000000000000000000000000000000000000000000000000000000\"" ++
        "}" ++
        "]," ++
        "\"rejections\":[]}";
    try std.testing.expectEqualStrings(expected, bytes);
}

test "semantic body canonicalizes RMSNorm contract when present" {
    const allocator = std.testing.allocator;
    const binding_roles = [_]schema.SemanticBodyBinding{
        .{ .binding_index = 0, .role = .input },
        .{ .binding_index = 1, .role = .scale },
        .{ .binding_index = 2, .role = .output },
    };
    const axis_roles = [_]schema.SemanticBodyAxis{
        .{ .axis_index = 0, .role = .hidden },
        .{ .axis_index = 1, .role = .reduction },
    };
    const body = schema.SemanticBody{
        .op = .rms_norm,
        .binding_roles = &binding_roles,
        .axis_roles = &axis_roles,
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

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try emitSemanticBody(&buf, allocator, body);

    try std.testing.expectEqualStrings(
        "{\"axisRoles\":[" ++
            "{\"axisIndex\":0,\"role\":\"hidden\"}," ++
            "{\"axisIndex\":1,\"role\":\"reduction\"}" ++
            "]," ++
            "\"bindingRoles\":[" ++
            "{\"bindingIndex\":0,\"role\":\"input\"}," ++
            "{\"bindingIndex\":1,\"role\":\"scale\"}," ++
            "{\"bindingIndex\":2,\"role\":\"output\"}" ++
            "]," ++
            "\"op\":\"rms_norm\"," ++
            "\"rmsNorm\":{" ++
            "\"epsilon\":{\"bindingIndex\":3,\"byteOffset\":4,\"literalF32\":null,\"path\":\"uniform:u.eps\",\"source\":\"uniform_field\"}," ++
            "\"formula\":\"sum_squares_mean_epsilon_rsqrt_scale\"," ++
            "\"hiddenExtentAxis\":0," ++
            "\"reductionTarget\":\"intermediate_scalar\"" ++
            "}" ++
            "}",
        buf.items,
    );
}

test "string escaping covers the canonical-form-reserved characters" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try emitString(&buf, allocator, "a\"b\\c\nd\te");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\"", buf.items);
}

test "empty realization canonicalizes to the expected JSON bytes" {
    const allocator = std.testing.allocator;
    const realization = schema.Realization{
        .functions = &.{},
        .emitter_digest = [_]u8{0} ** 32,
        .rejections = &.{},
    };
    const bytes = try canonicalizeRealization(allocator, realization);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(
        "{\"contractVersion\":1," ++
            "\"emitterDigest\":\"0000000000000000000000000000000000000000000000000000000000000000\"," ++
            "\"functions\":[]," ++
            "\"rejections\":[]}",
        bytes,
    );
}

test "realization with one function canonicalizes with lex-sorted keys and nulls for missing optionals" {
    const allocator = std.testing.allocator;
    const tile_factors = [_]u32{ 4, 8 };
    const residency = [_]schema.ResidencyDecision{
        .{
            .binding_index = 0,
            .class = .pe_sliced,
            .axis = 1,
            .shards = 4,
            // fabric_color and chunk_bytes left null (pe_sliced doesn't
            // use them); both should emit `null` in canonical JSON.
        },
    };
    const reductions = [_]schema.ReductionRealizationNode{
        .{ .semantic_index = 0, .tree_shape = .linear },
    };
    const rfuncs = [_]schema.RealizationFunction{
        .{
            .semantic_index = 0,
            .tiles = .{ .per_axis = &tile_factors },
            .pe_grid = .{ .width = 197, .height = 84 },
            .residency = &residency,
            .collectives = &.{},
            .reductions = &reductions,
            .emitter_params_json = "{}",
            .target_descriptor_hash = [_]u8{0xAB} ** 32,
        },
    };
    const realization = schema.Realization{
        .functions = &rfuncs,
        .emitter_digest = [_]u8{0xCD} ** 32,
        .rejections = &.{},
    };

    const bytes = try canonicalizeRealization(allocator, realization);
    defer allocator.free(bytes);

    const expected =
        "{\"contractVersion\":1," ++
        "\"emitterDigest\":\"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd\"," ++
        "\"functions\":[" ++
        "{\"collectives\":[]," ++
        "\"emitterParamsJson\":\"{}\"," ++
        "\"peGrid\":{\"height\":84,\"width\":197}," ++
        "\"reductions\":[{\"semanticIndex\":0,\"treeShape\":\"linear\"}]," ++
        "\"residency\":[" ++
        "{\"axis\":1,\"bindingIndex\":0,\"chunkBytes\":null," ++
        "\"class\":\"pe_sliced\",\"fabricColor\":null,\"shards\":4}" ++
        "]," ++
        "\"semanticIndex\":0," ++
        "\"targetDescriptorHash\":\"abababababababababababababababababababababababababababababababab\"," ++
        "\"tiles\":{\"perAxis\":[4,8]}" ++
        "}" ++
        "]," ++
        "\"rejections\":[]}";
    try std.testing.expectEqualStrings(expected, bytes);
}
