const std = @import("std");
const numeric_stability_policy = @import("../policy.zig");
const types = @import("numeric_stability_types.zig");

pub fn ensureValidRequest(request: types.Request) !void {
    if (!std.mem.eql(u8, request.moduleId, types.MODULE_ID)) return error.InvalidModuleId;
    if (!std.mem.eql(u8, request.artifactKind, "request")) return error.InvalidArtifactKind;
    if (!std.mem.eql(u8, request.serviceId, types.MATMUL_LOGITS_SLICE_SERVICE_ID)) return error.UnsupportedServiceId;
    if (!std.mem.eql(u8, request.operatorFamily, types.SUPPORTED_OPERATOR_FAMILY)) return error.UnsupportedOperatorFamily;
    if (!std.mem.eql(u8, request.semanticOpId, types.SUPPORTED_SEMANTIC_OP_ID)) return error.UnsupportedSemanticOpId;
    if (!std.mem.eql(u8, request.fastPolicyId, types.SUPPORTED_FAST_POLICY_ID)) return error.UnsupportedFastPolicy;
    if (!std.mem.eql(u8, request.stablePolicyId, types.SUPPORTED_STABLE_POLICY_ID)) return error.UnsupportedStablePolicy;
    if (request.hiddenState.len == 0) return error.HiddenStateEmpty;
    if (request.candidates.len < 2) return error.CandidateCountInvalid;
    for (request.candidates) |candidate| {
        if (candidate.weights.len != request.hiddenState.len) return error.CandidateLengthMismatch;
    }
}

pub fn ensureValidPolicy(policy: types.Policy) !void {
    try numeric_stability_policy.ensureValidRegistry(policy.registry);
}

pub fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

pub fn totalBytesMoved(request: types.Request) u64 {
    var total: u64 = @as(u64, @intCast(request.hiddenState.len)) * @sizeOf(f64);
    for (request.candidates) |candidate| {
        total += @as(u64, @intCast(candidate.weights.len)) * @sizeOf(f64);
        if (candidate.bias != null) total += @sizeOf(f64);
    }
    return total;
}

pub fn evaluateForwardF16(hidden_state: []const f64, weights: []const f64, bias: ?f64) f64 {
    var acc: f16 = 0;
    for (hidden_state, weights) |hidden_value, weight_value| {
        const lhs: f16 = @floatCast(hidden_value);
        const rhs: f16 = @floatCast(weight_value);
        acc = acc + lhs * rhs;
    }
    var out: f64 = @floatCast(acc);
    if (bias) |value| out += value;
    return out;
}

pub fn evaluateForwardF32(hidden_state: []const f64, weights: []const f64, bias: ?f64) f64 {
    var acc: f32 = 0;
    for (hidden_state, weights) |hidden_value, weight_value| {
        const lhs: f32 = @floatCast(hidden_value);
        const rhs: f32 = @floatCast(weight_value);
        acc = acc + lhs * rhs;
    }
    var out: f64 = @floatCast(acc);
    if (bias) |value| out += value;
    return out;
}

pub fn evaluateForwardF64(hidden_state: []const f64, weights: []const f64, bias: ?f64) f64 {
    var acc: f64 = 0;
    for (hidden_state, weights) |hidden_value, weight_value| {
        acc += hidden_value * weight_value;
    }
    if (bias) |value| acc += value;
    return acc;
}

pub fn selectedIndex(logits: []const f64) usize {
    var best_index: usize = 0;
    var best_value = logits[0];
    for (logits[1..], 1..) |value, index| {
        if (value > best_value) {
            best_value = value;
            best_index = index;
        }
    }
    return best_index;
}

pub fn appendReceiptCandidates(
    allocator: std.mem.Allocator,
    request: types.Request,
    fast_logits: []const f64,
    stable_logits: []const f64,
    reference_logits: []const f64,
) ![]types.ReceiptCandidate {
    var candidates = std.ArrayList(types.ReceiptCandidate).empty;
    defer candidates.deinit(allocator);
    for (request.candidates, 0..) |candidate, index| {
        try candidates.append(allocator, .{
            .tokenId = candidate.tokenId,
            .label = candidate.label,
            .fastLogit = fast_logits[index],
            .stableLogit = stable_logits[index],
            .referenceLogit = reference_logits[index],
        });
    }
    return try candidates.toOwnedSlice(allocator);
}
