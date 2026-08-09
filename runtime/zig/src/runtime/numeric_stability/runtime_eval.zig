const std = @import("std");
const execution = @import("../../runtime/execution.zig");
const numeric_stability_annotation = @import("../../contracts/numeric_stability/annotation.zig");
const numeric_stability_service = @import("service/numeric_stability.zig");
const artifact = @import("../../contracts/artifact.zig");
const runtime_plan = @import("runtime_plan.zig");
const f32_ops = @import("../../runtime/simd/f32_ops.zig");

const F32_BYTE_WIDTH: u64 = @sizeOf(f32);
const U32_WORD_BYTES: usize = @sizeOf(u32);

pub const DecisionMetrics = struct {
    candidates: []numeric_stability_service.ReceiptCandidate,
    fast_token: u32,
    stable_token: u32,
    reference_token: u32,
};

pub const Evaluation = struct {
    operator_family: []const u8,
    semantic_op_id: []const u8,
    semantic_stage: []const u8,
    semantic_phase: []const u8,
    trigger_policy_id: []const u8,
    routing_policy_id: []const u8,
    fast_policy_id: []const u8,
    stable_policy_id: []const u8,
    reference_policy_id: []const u8,
    candidates: []numeric_stability_service.ReceiptCandidate,
    fast_token: u32,
    stable_token: u32,
    reference_token: u32,
    fast_digest: []const u8,
    stable_digest: []const u8,
    rewrite_target_handle: u64,
    rewrite_target_offset: u64,
    rewrite_values: []const f64,
    execution_identity: numeric_stability_service.ExecutionIdentityReceipt,
};

pub fn evaluateMatmulObservation(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    observation: runtime_plan.MatmulObservation,
) !Evaluation {
    const hidden_state = try captureVector(
        allocator,
        execution_context,
        observation.hidden_state.buffer_handle,
        observation.hidden_state.offset,
        observation.hidden_state.element_count,
    );
    const fast_logits = try captureVector(
        allocator,
        execution_context,
        observation.logits.buffer_handle,
        observation.logits.offset,
        observation.logits.element_count,
    );
    var stable_logits = try allocator.alloc(f64, observation.candidates.len);
    var reference_logits = try allocator.alloc(f64, observation.candidates.len);
    for (observation.candidates, 0..) |candidate, index| {
        const weights = try captureWeightsRow(allocator, execution_context, observation.weights, candidate, hidden_state.len);
        stable_logits[index] = evaluateForwardF32(hidden_state, weights, candidate.bias);
        reference_logits[index] = evaluateForwardF64(hidden_state, weights, candidate.bias);
    }
    const metrics = try buildDecisionMetrics(allocator, observation.candidates, fast_logits, stable_logits, reference_logits);
    return .{
        .operator_family = observation.operator_family,
        .semantic_op_id = observation.semantic_op_id,
        .semantic_stage = observation.semantic_stage,
        .semantic_phase = observation.semantic_phase,
        .trigger_policy_id = observation.trigger_policy_id,
        .routing_policy_id = observation.routing_policy_id,
        .fast_policy_id = observation.fast_policy_id,
        .stable_policy_id = observation.stable_policy_id,
        .reference_policy_id = observation.reference_policy_id,
        .candidates = metrics.candidates,
        .fast_token = metrics.fast_token,
        .stable_token = metrics.stable_token,
        .reference_token = metrics.reference_token,
        .fast_digest = try artifact.stableHashJsonAlloc(allocator, fast_logits),
        .stable_digest = try artifact.stableHashJsonAlloc(allocator, stable_logits),
        .rewrite_target_handle = observation.logits.buffer_handle,
        .rewrite_target_offset = observation.logits.offset,
        .rewrite_values = stable_logits,
        .execution_identity = observation.execution_identity,
    };
}

pub fn evaluateRmsnormObservation(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    observation: runtime_plan.RmsnormObservation,
) !Evaluation {
    const input = try captureVector(
        allocator,
        execution_context,
        observation.input.buffer_handle,
        observation.input.offset,
        observation.input.element_count,
    );
    const weight = try captureVector(
        allocator,
        execution_context,
        observation.weight.buffer_handle,
        observation.weight.offset,
        observation.weight.element_count,
    );
    const fast_output = try captureVector(
        allocator,
        execution_context,
        observation.output.buffer_handle,
        observation.output.offset,
        observation.output.element_count,
    );
    const stable_output = try evaluateRmsnormSerialF32(allocator, input, weight, observation.size, observation.eps);
    const reference_output = try evaluateRmsnormSerialF64(allocator, input, weight, observation.size, observation.eps);
    const fast_logits = try evaluateMatmulAgainstHidden(
        allocator,
        execution_context,
        fast_output,
        observation.downstream_matmul.weights,
        observation.downstream_matmul.candidates,
    );
    const stable_logits = try evaluateMatmulAgainstHidden(
        allocator,
        execution_context,
        stable_output,
        observation.downstream_matmul.weights,
        observation.downstream_matmul.candidates,
    );
    const reference_logits = try evaluateMatmulAgainstHidden(
        allocator,
        execution_context,
        reference_output,
        observation.downstream_matmul.weights,
        observation.downstream_matmul.candidates,
    );
    const metrics = try buildDecisionMetrics(
        allocator,
        observation.downstream_matmul.candidates,
        fast_logits,
        stable_logits,
        reference_logits,
    );
    return .{
        .operator_family = observation.operator_family,
        .semantic_op_id = observation.semantic_op_id,
        .semantic_stage = observation.semantic_stage,
        .semantic_phase = observation.semantic_phase,
        .trigger_policy_id = observation.trigger_policy_id,
        .routing_policy_id = observation.routing_policy_id,
        .fast_policy_id = observation.fast_policy_id,
        .stable_policy_id = observation.stable_policy_id,
        .reference_policy_id = observation.reference_policy_id,
        .candidates = metrics.candidates,
        .fast_token = metrics.fast_token,
        .stable_token = metrics.stable_token,
        .reference_token = metrics.reference_token,
        .fast_digest = try artifact.stableHashJsonAlloc(allocator, fast_output),
        .stable_digest = try artifact.stableHashJsonAlloc(allocator, stable_output),
        .rewrite_target_handle = observation.output.buffer_handle,
        .rewrite_target_offset = observation.output.offset,
        .rewrite_values = stable_output,
        .execution_identity = observation.execution_identity,
    };
}

pub fn evaluateAttentionObservation(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    observation: runtime_plan.AttentionObservation,
) !Evaluation {
    const q = try captureVector(allocator, execution_context, observation.q.buffer_handle, observation.q.offset, observation.q.element_count);
    const k = try captureVector(allocator, execution_context, observation.k.buffer_handle, observation.k.offset, observation.k.element_count);
    const v = try captureVector(allocator, execution_context, observation.v.buffer_handle, observation.v.offset, observation.v.element_count);
    const fast_output = try captureVector(
        allocator,
        execution_context,
        observation.output.buffer_handle,
        observation.output.offset,
        observation.output.element_count,
    );
    const stable_output = try evaluateAttentionPairwiseF32(
        allocator,
        q,
        k,
        v,
        observation.seq_len,
        observation.head_dim,
        observation.scale,
    );
    const reference_output = try evaluateAttentionSerialF64(
        allocator,
        q,
        k,
        v,
        observation.seq_len,
        observation.head_dim,
        observation.scale,
    );
    const metrics = try buildDecisionMetrics(
        allocator,
        observation.candidates,
        fast_output,
        stable_output,
        reference_output,
    );
    return .{
        .operator_family = observation.operator_family,
        .semantic_op_id = observation.semantic_op_id,
        .semantic_stage = observation.semantic_stage,
        .semantic_phase = observation.semantic_phase,
        .trigger_policy_id = observation.trigger_policy_id,
        .routing_policy_id = observation.routing_policy_id,
        .fast_policy_id = observation.fast_policy_id,
        .stable_policy_id = observation.stable_policy_id,
        .reference_policy_id = observation.reference_policy_id,
        .candidates = metrics.candidates,
        .fast_token = metrics.fast_token,
        .stable_token = metrics.stable_token,
        .reference_token = metrics.reference_token,
        .fast_digest = try artifact.stableHashJsonAlloc(allocator, fast_output),
        .stable_digest = try artifact.stableHashJsonAlloc(allocator, stable_output),
        .rewrite_target_handle = observation.output.buffer_handle,
        .rewrite_target_offset = observation.output.offset,
        .rewrite_values = stable_output,
        .execution_identity = observation.execution_identity,
    };
}

pub fn buildDecisionMetrics(
    allocator: std.mem.Allocator,
    candidates: []const numeric_stability_annotation.Candidate,
    fast_values: []const f64,
    stable_values: []const f64,
    reference_values: []const f64,
) !DecisionMetrics {
    var receipt_candidates = try allocator.alloc(numeric_stability_service.ReceiptCandidate, candidates.len);
    for (candidates, 0..) |candidate, index| {
        receipt_candidates[index] = .{
            .tokenId = candidate.token_id,
            .label = candidate.label,
            .fastLogit = fast_values[index],
            .stableLogit = stable_values[index],
            .referenceLogit = reference_values[index],
        };
    }
    const fast_index = selectedIndex(fast_values);
    const stable_index = selectedIndex(stable_values);
    const reference_index = selectedIndex(reference_values);
    return .{
        .candidates = receipt_candidates,
        .fast_token = candidates[fast_index].token_id,
        .stable_token = candidates[stable_index].token_id,
        .reference_token = candidates[reference_index].token_id,
    };
}

pub fn executeStableRewrite(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    buffer_handle: u64,
    offset: u64,
    values: []const f64,
) !void {
    var words = try allocator.alloc(u32, values.len);
    for (values, 0..) |value, index| {
        const f32_value: f32 = @floatCast(value);
        words[index] = @bitCast(f32_value);
    }
    const result = try execution_context.execute(.{ .buffer_write = .{
        .handle = buffer_handle,
        .offset = offset,
        .buffer_size = @as(u64, @intCast(words.len * U32_WORD_BYTES)),
        .data = words,
    } });
    if (result.status != .ok) return error.NumericStabilityRewriteFailed;
}

pub fn captureVector(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    buffer_handle: u64,
    offset: u64,
    element_count: u32,
) ![]f64 {
    const byte_size = @as(u64, element_count) * F32_BYTE_WIDTH;
    const bytes = try execution_context.captureBuffer(allocator, buffer_handle, offset, byte_size);
    defer allocator.free(bytes);
    return try decodeF32Vector(allocator, bytes, element_count);
}

pub fn captureWeightsRow(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    weights_capture: numeric_stability_annotation.WeightsCapture,
    candidate: numeric_stability_annotation.Candidate,
    hidden_len: usize,
) ![]f64 {
    const row_offset = weights_capture.offset +
        (@as(u64, candidate.row_index) * @as(u64, weights_capture.row_stride_elements) * F32_BYTE_WIDTH);
    const byte_size = @as(u64, @intCast(hidden_len)) * F32_BYTE_WIDTH;
    const bytes = try execution_context.captureBuffer(
        allocator,
        weights_capture.buffer_handle,
        row_offset,
        byte_size,
    );
    defer allocator.free(bytes);
    return try decodeF32Vector(allocator, bytes, @intCast(hidden_len));
}

pub fn evaluateForwardF32(hidden_state: []const f64, weights: []const f64, bias: ?f64) f64 {
    var acc: f32 = 0;
    for (hidden_state, weights) |hidden_value, weight_value| {
        acc = acc + @as(f32, @floatCast(hidden_value)) * @as(f32, @floatCast(weight_value));
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

pub fn evaluateMatmulAgainstHidden(
    allocator: std.mem.Allocator,
    execution_context: *execution.ExecutionContext,
    hidden_state: []const f64,
    weights_capture: numeric_stability_annotation.WeightsCapture,
    candidates: []const numeric_stability_annotation.Candidate,
) ![]f64 {
    var logits = try allocator.alloc(f64, candidates.len);
    for (candidates, 0..) |candidate, index| {
        const weights = try captureWeightsRow(allocator, execution_context, weights_capture, candidate, hidden_state.len);
        logits[index] = evaluateForwardF64(hidden_state, weights, candidate.bias);
    }
    return logits;
}

pub fn evaluateRmsnormSerialF32(
    allocator: std.mem.Allocator,
    input: []const f64,
    weight: []const f64,
    size: u32,
    eps: f64,
) ![]f64 {
    if (size == 0 or input.len % size != 0) return error.NumericStabilityInvalidRmsnormShape;
    const rows = input.len / size;
    var output = try allocator.alloc(f64, input.len);
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        const row_offset = row * size;
        var sum_sq: f32 = 0;
        var col: usize = 0;
        while (col < size) : (col += 1) {
            const value: f32 = @floatCast(input[row_offset + col]);
            sum_sq = sum_sq + value * value;
        }
        const denom = @as(f32, @floatCast(@as(f64, @floatCast(sum_sq)) / @as(f64, @floatFromInt(size)) + eps));
        const rms: f32 = 1.0 / @sqrt(denom);
        col = 0;
        while (col < size) : (col += 1) {
            output[row_offset + col] =
                @as(f64, @floatCast(@as(f32, @floatCast(input[row_offset + col])) * rms * @as(f32, @floatCast(weight[col]))));
        }
    }
    return output;
}

pub fn evaluateRmsnormSerialF64(
    allocator: std.mem.Allocator,
    input: []const f64,
    weight: []const f64,
    size: u32,
    eps: f64,
) ![]f64 {
    if (size == 0 or input.len % size != 0) return error.NumericStabilityInvalidRmsnormShape;
    const rows = input.len / size;
    var output = try allocator.alloc(f64, input.len);
    var row: usize = 0;
    while (row < rows) : (row += 1) {
        const row_offset = row * size;
        var sum_sq: f64 = 0;
        var col: usize = 0;
        while (col < size) : (col += 1) {
            const value = input[row_offset + col];
            sum_sq += value * value;
        }
        const rms = 1.0 / @sqrt(sum_sq / @as(f64, @floatFromInt(size)) + eps);
        col = 0;
        while (col < size) : (col += 1) {
            output[row_offset + col] = input[row_offset + col] * rms * weight[col];
        }
    }
    return output;
}

pub fn evaluateAttentionPairwiseF32(
    allocator: std.mem.Allocator,
    q: []const f64,
    k: []const f64,
    v: []const f64,
    seq_len: u32,
    head_dim: u32,
    scale: f64,
) ![]f64 {
    return try evaluateAttention(allocator, q, k, v, seq_len, head_dim, scale, .pairwise_f32);
}

pub fn evaluateAttentionSerialF64(
    allocator: std.mem.Allocator,
    q: []const f64,
    k: []const f64,
    v: []const f64,
    seq_len: u32,
    head_dim: u32,
    scale: f64,
) ![]f64 {
    return try evaluateAttention(allocator, q, k, v, seq_len, head_dim, scale, .serial_f64);
}

const AttentionEvalMode = enum {
    pairwise_f32,
    serial_f64,
};

const AttentionScratch = struct {
    allocator: std.mem.Allocator,
    weighted: []f64 = &.{},

    fn init(allocator: std.mem.Allocator) AttentionScratch {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *AttentionScratch) void {
        if (self.weighted.len > 0) {
            self.allocator.free(self.weighted);
            self.weighted = &.{};
        }
    }

    fn ensureWeighted(self: *AttentionScratch, len: usize) ![]f64 {
        if (self.weighted.len < len) {
            if (self.weighted.len > 0) {
                self.allocator.free(self.weighted);
            }
            self.weighted = try self.allocator.alloc(f64, len);
        }
        return self.weighted[0..len];
    }
};

fn evaluateAttention(
    allocator: std.mem.Allocator,
    q: []const f64,
    k: []const f64,
    v: []const f64,
    seq_len: u32,
    head_dim: u32,
    scale: f64,
    mode: AttentionEvalMode,
) ![]f64 {
    if (seq_len == 0 or head_dim == 0) return error.NumericStabilityInvalidAttentionShape;
    if (q.len != @as(usize, head_dim)) return error.NumericStabilityInvalidAttentionShape;
    if (k.len != @as(usize, seq_len) * @as(usize, head_dim)) return error.NumericStabilityInvalidAttentionShape;
    if (v.len % @as(usize, seq_len) != 0) return error.NumericStabilityInvalidAttentionShape;
    const value_dim = v.len / @as(usize, seq_len);
    var scratch = AttentionScratch.init(allocator);
    defer scratch.deinit();
    var scores = try allocator.alloc(f64, seq_len);
    defer allocator.free(scores);
    var position: usize = 0;
    while (position < seq_len) : (position += 1) {
        const start = position * head_dim;
        const key_row = k[start .. start + head_dim];
        scores[position] = switch (mode) {
            .pairwise_f32 => @as(f64, @floatCast(pairwiseDotF32(q, key_row) * @as(f32, @floatCast(scale)))),
            .serial_f64 => serialDotF64(q, key_row) * scale,
        };
    }
    const row_max = maxValue(scores);
    var exps = try allocator.alloc(f64, seq_len);
    defer allocator.free(exps);
    for (scores, 0..) |score, index| {
        const shifted = @max(@min(score - row_max, 30.0), -30.0);
        exps[index] = switch (mode) {
            .pairwise_f32 => @as(f64, @floatCast(@exp(@as(f32, @floatCast(shifted))))),
            .serial_f64 => @exp(shifted),
        };
    }
    const total = switch (mode) {
        .pairwise_f32 => @as(f64, @floatCast(pairwiseReduceF32(exps))),
        .serial_f64 => serialSumF64(exps),
    };
    var output = try allocator.alloc(f64, value_dim);
    errdefer allocator.free(output);
    var value_index: usize = 0;
    while (value_index < value_dim) : (value_index += 1) {
        const weighted = try scratch.ensureWeighted(@as(usize, seq_len));
        for (exps, 0..) |value, seq_index| {
            const prob = value / total;
            weighted[seq_index] = prob * v[(seq_index * value_dim) + value_index];
        }
        output[value_index] = switch (mode) {
            .pairwise_f32 => @as(f64, @floatCast(pairwiseReduceF32(weighted))),
            .serial_f64 => serialSumF64(weighted),
        };
    }
    return output;
}

fn pairwiseDotF32(lhs: []const f64, rhs: []const f64) f32 {
    return f32_ops.dotF64(lhs, rhs);
}

fn pairwiseReduceF32(values: []const f64) f32 {
    if (values.len == 0) return 0;
    return f32_ops.sumF64(values);
}

fn serialDotF64(lhs: []const f64, rhs: []const f64) f64 {
    var sum: f64 = 0;
    for (lhs, rhs) |left, right| sum += left * right;
    return sum;
}

fn serialSumF64(values: []const f64) f64 {
    var sum: f64 = 0;
    for (values) |value| sum += value;
    return sum;
}

fn maxValue(values: []const f64) f64 {
    var best = values[0];
    for (values[1..]) |value| {
        if (value > best) best = value;
    }
    return best;
}

fn decodeF32Vector(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    element_count: u32,
) ![]f64 {
    if (bytes.len != @as(usize, element_count) * @sizeOf(f32)) return error.NumericStabilityCaptureSizeMismatch;
    var values = try allocator.alloc(f64, element_count);
    var index: usize = 0;
    while (index < element_count) : (index += 1) {
        const start = index * @sizeOf(f32);
        const chunk: *const [4]u8 = @ptrCast(bytes[start .. start + @sizeOf(f32)].ptr);
        const bits = std.mem.readInt(u32, chunk, .little);
        const value: f32 = @bitCast(bits);
        values[index] = @as(f64, @floatCast(value));
    }
    return values;
}

fn selectedIndex(logits: []const f64) usize {
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
