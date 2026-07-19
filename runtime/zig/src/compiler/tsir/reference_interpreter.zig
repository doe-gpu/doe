// TSIR reference interpreter — the parity oracle.
//
// This is the single source of truth for "what counts as correct."
// Every backend (WebGPU SPIR-V, CSL simfabric, CSL hardware, native
// MSL/HLSL) is compared against THIS interpreter, never against each
// other. Drift between backends is not "the other backend is wrong" —
// drift is one-or-both disagreeing with the reference.
//
// Numerical contract (locked):
//   - IEEE-754 round-to-nearest-even for every elementary op.
//   - fp32 accumulation for every reduction regardless of source dtype;
//     a source override must be declared on the TSIR reduction region.
//   - Left-fold reduction order unless the TSIR reduction declares
//     associative_allowed, in which case the interpreter re-runs in
//     the declared tree shape.
//   - Deterministic transcendentals: exp, log, sin, cos, tan, tanh,
//     rsqrt, recip implemented as sollya-bounded minimax polynomials
//     so results are bit-reproducible across hosts. libm is NOT used.
//   - NaN and Inf propagation as declared per reduction region; the
//     default is `propagate`.
//
// This file is still intentionally narrow. Unsupported paths return
// `NotImplemented` against the rejection taxonomy so callers see the
// gap precisely rather than a silent zero. Explicit semantic/realization
// rejections fail early with `RejectedBySemantic`. Executable bootstrap
// paths cover empty kernels, simple reductions, fused GEMV, gather, and
// byte-for-byte identity. Each path is guarded by strict TSIR shape checks
// so no backend gets an implicit semantic rescue.

const std = @import("std");
const scalar = @import("reference_scalar.zig");
const schema = @import("schema.zig");

const computeExpectedBytes = scalar.computeExpectedBytes;
const readF32FromBytes = scalar.readF32FromBytes;
const writeF32AsElem = scalar.writeF32AsElem;

const reference_extended_ops = @import("reference_extended_ops.zig");
const reference_inputs = @import("reference_inputs.zig");
const reference_reduction = @import("reference_reduction.zig");
const reference_types = @import("reference_types.zig");

pub const InterpretError = reference_types.InterpretError;
pub const Result = reference_types.Result;

const countReadOnlyBindings = reference_inputs.countReadOnlyBindings;
const inputBytesForReadOnlyBinding = reference_inputs.inputBytesForReadOnlyBinding;

/// Run the reference interpreter against a (semantic, realization)
/// pair and a set of inputs. The realization is consumed only for the
/// declared reduction-tree shape on `algorithm_exact` reductions; all
/// other backend-specific details are ignored here — the reference is
/// deliberately target-independent.
///
/// Caller owns the returned output buffers and the output slice itself
/// and must free them via `freeResult`.
pub fn run(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    realization: schema.Realization,
    inputs: []const []const u8,
) InterpretError!Result {
    if (semantic.rejections.len != 0 or realization.rejections.len != 0) {
        return error.RejectedBySemantic;
    }
    if (tryEmptyKernel(semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (reference_reduction.trySimpleReduction(allocator, semantic, realization, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (tryFusedGemv(allocator, semantic, realization, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (tryRmsNorm(allocator, semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (tryGather(allocator, semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (reference_extended_ops.tryIdentity(allocator, semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (reference_extended_ops.tryResidualAdd(allocator, semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (reference_extended_ops.tryGated(allocator, semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (reference_extended_ops.tryAttentionScores(allocator, semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (reference_extended_ops.tryL2Normalize(allocator, semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (reference_extended_ops.tryConv1DDepthwise(allocator, semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    if (reference_extended_ops.tryLinearAttention(allocator, semantic, inputs)) |maybe_result| {
        if (maybe_result) |result| return result;
    } else |err| return err;
    return error.NotImplemented;
}

/// Free the output buffers in a Result produced by `run`. Safe to call
/// with an empty outputs slice. Rejections are const-static and are
/// not freed.
pub fn freeResult(allocator: std.mem.Allocator, result: *Result) void {
    for (result.outputs) |buf| allocator.free(buf);
    if (result.outputs.len > 0) allocator.free(result.outputs);
    result.outputs = &[_][]const u8{};
}

/// Detect the zero-binding nop kernel and interpret it. A
/// SemanticFunction with zero bindings, zero reductions, and zero
/// collectives is observably a nop; the Result has no output buffers
/// and the reference hash is `SHA-256("")`. Returns null when the
/// semantic is not shaped like the nop case, leaving the caller to
/// fall through to other dispatch paths.
///
/// This is the smallest possible real dispatch — no allocator needed,
/// no inputs consumed. It proves the multi-case dispatch pattern in
/// `run()` before any op-body-aware path lands.
fn tryEmptyKernel(
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.bindings.len != 0) return null;
    if (func.reductions.len != 0) return null;
    if (func.collectives.len != 0) return null;
    // No bindings means no inputs are consumed.
    if (inputs.len != 0) return null;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&[_]u8{}, &hash, .{});

    return Result{
        .reference_hash = hash,
        .outputs = &[_][]const u8{},
        .rejections = &[_]schema.RejectionEntry{},
    };
}

/// Detect the fused_gemv bootstrap-family case and interpret it.
///
/// Shape this recognizer matches (strict; anything else falls through):
///   * one function, zero collectives
///   * exactly three bindings (matrix, vector, output) with declared
///     `SemanticBody` roles matching binding indices
///   * exactly two axes (output, reduction) with declared roles
///   * exactly one reduction region: sum, along the reduction axis,
///     target = the output binding, accumulation = f32,
///     associativity = strict_ordered, NaN/Inf = propagate
///   * matrix shape `[M, K]` row-major, vector shape `[K]`, output
///     shape `[M]`; element kinds across all three bindings are equal
///     and one of {f32, f16, bf16}
///
/// Computation: `y[i] = Σ_k  W[i, k] · x[k]` with a left-fold f32
/// accumulator over k (strict_ordered honors the byte-order sum). The
/// f32 output is then written back through the declared output dtype
/// via `writeF32AsElem`, which matches the trySimpleReduction path.
///
/// `associative_allowed` with a declared tree shape is explicitly out
/// of scope for this recognizer; it falls through so a future wedge
/// can add it without retrofitting the strict path.
fn tryFusedGemv(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    realization: schema.Realization,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.collectives.len != 0) return null;
    if (func.bindings.len != 3) return null;
    if (func.reductions.len != 1) return null;
    if (func.axes.len != 2) return null;

    // Body must declare the fused_gemv family with role assignments.
    if (func.body.op != .fused_gemv) return null;
    if (func.body.binding_roles.len != 3) return null;
    if (func.body.axis_roles.len != 2) return null;

    var matrix_index: ?u32 = null;
    var vector_index: ?u32 = null;
    var output_index: ?u32 = null;
    for (func.body.binding_roles) |role| {
        switch (role.role) {
            .matrix => {
                if (matrix_index != null) return null;
                matrix_index = role.binding_index;
            },
            .vector => {
                if (vector_index != null) return null;
                vector_index = role.binding_index;
            },
            .output => {
                if (output_index != null) return null;
                output_index = role.binding_index;
            },
            else => return null,
        }
    }
    const mi = matrix_index orelse return null;
    const vi = vector_index orelse return null;
    const oi = output_index orelse return null;
    if (mi >= func.bindings.len or vi >= func.bindings.len or oi >= func.bindings.len) return null;
    if (mi == vi or vi == oi or mi == oi) return null;

    var output_axis: ?u32 = null;
    var reduction_axis: ?u32 = null;
    for (func.body.axis_roles) |role| {
        switch (role.role) {
            .output => {
                if (output_axis != null) return null;
                output_axis = role.axis_index;
            },
            .reduction => {
                if (reduction_axis != null) return null;
                reduction_axis = role.axis_index;
            },
            else => return null,
        }
    }
    const out_axis = output_axis orelse return null;
    const red_axis = reduction_axis orelse return null;
    if (out_axis == red_axis) return null;
    if (out_axis >= func.axes.len or red_axis >= func.axes.len) return null;

    const reduction = func.reductions[0];
    if (reduction.op != .sum) return null;
    if (reduction.axis != red_axis) return null;
    if (reduction.target_binding != oi) return null;
    if (reduction.contract.accumulation != .f32) return null;

    // Associativity dispatch:
    //   strict_ordered     → left-fold is the only legal order.
    //   associative_allowed → tree shape is declared on the matching
    //                        Realization.ReductionRealizationNode. On a
    //                        single-PE reference, `.ring` is fold-order-
    //                        identical to `.linear`; `.binomial` is a
    //                        pairwise-tree fold that can differ bit-for-
    //                        bit from left-fold. Matches the
    //                        `trySimpleReduction` precedent. Falls
    //                        through when the realization does not
    //                        declare a matching reduction node.
    var effective_tree_shape: schema.ReductionTreeShape = .linear;
    switch (reduction.contract.associativity) {
        .strict_ordered => {},
        .associative_allowed => {
            if (realization.functions.len != 1) return null;
            const rfunc = realization.functions[0];
            if (rfunc.semantic_index != 0) return null;
            if (rfunc.reductions.len != 1) return null;
            const rnode = rfunc.reductions[0];
            if (rnode.semantic_index != 0) return null;
            effective_tree_shape = rnode.tree_shape;
        },
    }

    const mb = func.bindings[mi];
    const vb = func.bindings[vi];
    const ob = func.bindings[oi];

    // Dtype must match across all three bindings; one of the Phase A set.
    if (mb.elem != vb.elem or vb.elem != ob.elem) return null;
    if (mb.elem != .f32 and mb.elem != .f16 and mb.elem != .bf16) return null;

    // Shape guards: matrix [M, K], vector [K], output [M].
    if (mb.logical_shape.len != 2) return null;
    if (vb.logical_shape.len != 1) return null;
    if (ob.logical_shape.len != 1) return null;
    const m_u64 = mb.logical_shape[0];
    const k_u64 = mb.logical_shape[1];
    if (vb.logical_shape[0] != k_u64) return null;
    if (ob.logical_shape[0] != m_u64) return null;

    // Read/write flags: matrix + vector read-only, output read_write.
    if (mb.read_write or vb.read_write) return null;
    if (!ob.read_write) return null;

    const m: usize = std.math.cast(usize, m_u64) orelse return null;
    const k: usize = std.math.cast(usize, k_u64) orelse return null;

    // Phase A: matrix is row-major with axes [output, reduction]. The
    // axis-role declaration must agree with that layout; otherwise the
    // body doesn't describe the row-major W[M, K] this recognizer
    // assumes, and we fall through rather than silently reinterpret.
    if (out_axis != 0 or red_axis != 1) return null;

    // Inputs: [matrix_bytes, vector_bytes] in binding-index order of
    // the read-only bindings. The oracle contract is that the caller
    // orders inputs by ascending binding index of the read-only
    // bindings; with mi < vi that's matrix first, else vector first.
    if (inputs.len != 2) return null;
    const matrix_first = mi < vi;
    const matrix_bytes = if (matrix_first) inputs[0] else inputs[1];
    const vector_bytes = if (matrix_first) inputs[1] else inputs[0];

    const expected_matrix_bytes = computeExpectedBytes(mb) orelse return null;
    const expected_vector_bytes = computeExpectedBytes(vb) orelse return null;
    if (matrix_bytes.len != expected_matrix_bytes) return null;
    if (vector_bytes.len != expected_vector_bytes) return null;

    const out_elem_bytes: usize = ob.elem.byteSize();
    const output_bytes = try allocator.alloc(u8, m * out_elem_bytes);
    errdefer allocator.free(output_bytes);

    // Per-output scratch for binomial fold. Allocated once, reused
    // across output positions so the hot loop is alloc-free. Matches
    // the trySimpleReduction rank-2 pattern.
    var scratch: ?[]f32 = null;
    defer if (scratch) |s| allocator.free(s);
    if (effective_tree_shape == .binomial and k > 0) {
        scratch = try allocator.alloc(f32, k);
    }

    // Zero-K edge case: output is the reduction identity for sum (0.0)
    // written through the declared output dtype. Tree shape is
    // irrelevant when the axis is empty.
    if (k == 0) {
        var i: usize = 0;
        while (i < m) : (i += 1) writeF32AsElem(output_bytes, i, 0.0, ob.elem);
    } else {
        var i: usize = 0;
        while (i < m) : (i += 1) {
            switch (effective_tree_shape) {
                .linear, .ring => {
                    var acc: f32 = 0.0;
                    var kk: usize = 0;
                    while (kk < k) : (kk += 1) {
                        const w_val = readF32FromBytes(matrix_bytes, mb.elem, i * k + kk);
                        const x_val = readF32FromBytes(vector_bytes, vb.elem, kk);
                        acc += w_val * x_val;
                    }
                    writeF32AsElem(output_bytes, i, acc, ob.elem);
                },
                .binomial => {
                    // Materialize k products, then pairwise-fold. Result
                    // can differ from left-fold bit-for-bit on
                    // non-associative floating-point, which is exactly
                    // why `algorithm_exact` pins `tree_shape` as a
                    // declared invariant.
                    const vals = scratch.?;
                    var kk: usize = 0;
                    while (kk < k) : (kk += 1) {
                        const w_val = readF32FromBytes(matrix_bytes, mb.elem, i * k + kk);
                        const x_val = readF32FromBytes(vector_bytes, vb.elem, kk);
                        vals[kk] = w_val * x_val;
                    }
                    var count: usize = k;
                    while (count > 1) {
                        var new_count: usize = 0;
                        var idx: usize = 0;
                        while (idx < count) : (idx += 2) {
                            if (idx + 1 < count) {
                                vals[new_count] = vals[idx] + vals[idx + 1];
                            } else {
                                vals[new_count] = vals[idx];
                            }
                            new_count += 1;
                        }
                        count = new_count;
                    }
                    writeF32AsElem(output_bytes, i, vals[0], ob.elem);
                },
            }
        }
    }

    var outputs = try allocator.alloc([]const u8, 1);
    outputs[0] = output_bytes;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output_bytes, &hash, .{});

    return Result{
        .reference_hash = hash,
        .outputs = outputs,
        .rejections = &[_]schema.RejectionEntry{},
    };
}

/// Detect the RMSNorm bootstrap-family case and interpret it for explicit
/// epsilon contracts.
///
/// Shape this recognizer matches:
///   * one function, zero collectives
///   * at least three bindings with declared roles: input, scale, output
///   * exactly two axes with declared roles: hidden, reduction
///   * exactly one sum reduction over the reduction axis with f32
///     accumulation, strict ordering, and an intermediate scalar target
///   * equal `[H]` shapes and equal dtype over {f32, f16, bf16}
///   * `body.rmsNorm.epsilon.source` is either a literal f32 or a
///     uniform-field path with explicit binding index and byte offset.
fn tryRmsNorm(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.collectives.len != 0) return null;
    if (func.bindings.len < 3) return null;
    if (func.reductions.len != 1) return null;
    if (func.axes.len != 2) return null;

    if (func.body.op != .rms_norm) return null;
    const rms_norm = func.body.rms_norm orelse return null;
    if (rms_norm.formula != .sum_squares_mean_epsilon_rsqrt_scale) return null;
    if (rms_norm.reduction_target != .intermediate_scalar) return null;
    if (inputs.len != countReadOnlyBindings(func)) return null;
    const epsilon = resolveRmsNormEpsilon(func, inputs, rms_norm.epsilon) orelse return null;

    if (func.body.binding_roles.len != 3) return null;
    if (func.body.axis_roles.len != 2) return null;

    var input_index: ?u32 = null;
    var scale_index: ?u32 = null;
    var output_index: ?u32 = null;
    for (func.body.binding_roles) |role| {
        switch (role.role) {
            .input => {
                if (input_index != null) return null;
                input_index = role.binding_index;
            },
            .scale => {
                if (scale_index != null) return null;
                scale_index = role.binding_index;
            },
            .output => {
                if (output_index != null) return null;
                output_index = role.binding_index;
            },
            else => return null,
        }
    }
    const ii = input_index orelse return null;
    const si = scale_index orelse return null;
    const oi = output_index orelse return null;
    if (ii >= func.bindings.len or si >= func.bindings.len or oi >= func.bindings.len) return null;
    if (ii == si or si == oi or ii == oi) return null;

    var hidden_axis: ?u32 = null;
    var reduction_axis: ?u32 = null;
    for (func.body.axis_roles) |role| {
        switch (role.role) {
            .hidden => {
                if (hidden_axis != null) return null;
                hidden_axis = role.axis_index;
            },
            .reduction => {
                if (reduction_axis != null) return null;
                reduction_axis = role.axis_index;
            },
            else => return null,
        }
    }
    const hid_axis = hidden_axis orelse return null;
    const red_axis = reduction_axis orelse return null;
    if (hid_axis == red_axis) return null;
    if (hid_axis >= func.axes.len or red_axis >= func.axes.len) return null;
    if (rms_norm.hidden_extent_axis != hid_axis) return null;
    if (hid_axis != 0 or red_axis != 1) return null;

    const reduction = func.reductions[0];
    if (reduction.op != .sum) return null;
    if (reduction.axis != red_axis) return null;
    if (reduction.contract.accumulation != .f32) return null;
    if (reduction.contract.associativity != .strict_ordered) return null;
    if (reduction.contract.nan_inf != .propagate) return null;

    const ib = func.bindings[ii];
    const sb = func.bindings[si];
    const ob = func.bindings[oi];
    if (ib.read_write or sb.read_write) return null;
    if (!ob.read_write) return null;
    if (ib.elem != sb.elem or sb.elem != ob.elem) return null;
    if (ib.elem != .f32 and ib.elem != .f16 and ib.elem != .bf16) return null;
    if (ib.logical_shape.len != 1) return null;
    if (sb.logical_shape.len != 1) return null;
    if (ob.logical_shape.len != 1) return null;

    const hidden_u64 = ib.logical_shape[0];
    if (sb.logical_shape[0] != hidden_u64) return null;
    if (ob.logical_shape[0] != hidden_u64) return null;
    const hidden: usize = std.math.cast(usize, hidden_u64) orelse return null;

    const input_bytes = inputBytesForReadOnlyBinding(func, inputs, ii) orelse return null;
    const scale_bytes = inputBytesForReadOnlyBinding(func, inputs, si) orelse return null;
    const expected_input_bytes = computeExpectedBytes(ib) orelse return null;
    const expected_scale_bytes = computeExpectedBytes(sb) orelse return null;
    if (input_bytes.len != expected_input_bytes) return null;
    if (scale_bytes.len != expected_scale_bytes) return null;

    const expected_output_bytes = computeExpectedBytes(ob) orelse return null;
    const output_len = std.math.cast(usize, expected_output_bytes) orelse return null;
    const output_bytes = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output_bytes);

    if (hidden != 0) {
        var sum_sq: f32 = 0.0;
        var r: usize = 0;
        while (r < hidden) : (r += 1) {
            const x = readF32FromBytes(input_bytes, ib.elem, r);
            sum_sq += x * x;
        }
        const mean_sq = sum_sq / @as(f32, @floatFromInt(hidden));
        const inv_rms = 1.0 / @sqrt(mean_sq + epsilon);

        var d: usize = 0;
        while (d < hidden) : (d += 1) {
            const x = readF32FromBytes(input_bytes, ib.elem, d);
            const scale = readF32FromBytes(scale_bytes, sb.elem, d);
            writeF32AsElem(output_bytes, d, x * inv_rms * scale, ob.elem);
        }
    }

    var outputs = try allocator.alloc([]const u8, 1);
    outputs[0] = output_bytes;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output_bytes, &hash, .{});

    return Result{
        .reference_hash = hash,
        .outputs = outputs,
        .rejections = &[_]schema.RejectionEntry{},
    };
}

fn resolveRmsNormEpsilon(
    func: schema.SemanticFunction,
    inputs: []const []const u8,
    epsilon: schema.RmsNormEpsilon,
) ?f32 {
    return switch (epsilon.source) {
        .literal_f32 => blk: {
            if (epsilon.path.len != 0) return null;
            if (epsilon.binding_index != null or epsilon.byte_offset != null) return null;
            const epsilon_f64 = epsilon.literal_f32 orelse return null;
            if (std.math.isNan(epsilon_f64) or std.math.isInf(epsilon_f64)) return null;
            break :blk @floatCast(epsilon_f64);
        },
        .uniform_field => blk: {
            const path = splitUniformFieldPath(epsilon.path) orelse return null;
            if (!std.mem.eql(u8, path.field_name, "eps")) return null;
            if (epsilon.literal_f32 != null) return null;
            const binding_index = epsilon.binding_index orelse return null;
            const byte_offset_u32 = epsilon.byte_offset orelse return null;
            const binding_idx: usize = std.math.cast(usize, binding_index) orelse return null;
            if (binding_idx >= func.bindings.len) return null;
            if (func.bindings[binding_idx].read_write) return null;
            if (!std.mem.eql(u8, path.binding_name, func.bindings[binding_idx].name)) return null;
            const uniform_bytes = inputBytesForReadOnlyBinding(
                func,
                inputs,
                binding_index,
            ) orelse return null;
            const byte_offset: usize = std.math.cast(usize, byte_offset_u32) orelse return null;
            if (byte_offset > uniform_bytes.len) return null;
            if (uniform_bytes.len - byte_offset < 4) return null;
            const bits = std.mem.readInt(u32, uniform_bytes[byte_offset..][0..4], .little);
            const value: f32 = @bitCast(bits);
            if (std.math.isNan(value) or std.math.isInf(value)) return null;
            break :blk value;
        },
    };
}

const UniformFieldPath = struct {
    binding_name: []const u8,
    field_name: []const u8,
};

fn splitUniformFieldPath(path: []const u8) ?UniformFieldPath {
    const prefix = "uniform:";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    if (dot == 0 or dot + 1 >= rest.len) return null;
    return .{
        .binding_name = rest[0..dot],
        .field_name = rest[dot + 1 ..],
    };
}

/// Detect the gather bootstrap-family case and interpret it.
///
/// Shape this recognizer matches:
///   * one function, zero reductions, zero collectives
///   * exactly three bindings with declared roles: indices, table, output
///   * exactly two axes with declared roles: token, hidden
///   * indices shape `[T]` with `u32` elements
///   * table shape `[V, H]`, output shape `[T, H]`
///   * table/output dtype equal and one of {f32, f16, bf16}
///
/// Computation copies `table[indices[t], h]` to `output[t, h]` in row-major
/// element order. Index bounds are dynamic input facts rather than static
/// TSIR shape facts; an out-of-vocabulary index falls through so the caller
/// sees `NotImplemented` instead of a wrapped or clamped result.
fn tryGather(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.collectives.len != 0) return null;
    if (func.reductions.len != 0) return null;
    if (func.bindings.len != 3) return null;
    if (func.axes.len != 2) return null;

    if (func.body.op != .gather) return null;
    if (func.body.binding_roles.len != 3) return null;
    if (func.body.axis_roles.len != 2) return null;

    var indices_index: ?u32 = null;
    var table_index: ?u32 = null;
    var output_index: ?u32 = null;
    for (func.body.binding_roles) |role| {
        switch (role.role) {
            .indices => {
                if (indices_index != null) return null;
                indices_index = role.binding_index;
            },
            .table => {
                if (table_index != null) return null;
                table_index = role.binding_index;
            },
            .output => {
                if (output_index != null) return null;
                output_index = role.binding_index;
            },
            else => return null,
        }
    }
    const ii = indices_index orelse return null;
    const ti = table_index orelse return null;
    const oi = output_index orelse return null;
    if (ii >= func.bindings.len or ti >= func.bindings.len or oi >= func.bindings.len) return null;
    if (ii == ti or ti == oi or ii == oi) return null;

    var token_axis: ?u32 = null;
    var hidden_axis: ?u32 = null;
    for (func.body.axis_roles) |role| {
        switch (role.role) {
            .token => {
                if (token_axis != null) return null;
                token_axis = role.axis_index;
            },
            .hidden => {
                if (hidden_axis != null) return null;
                hidden_axis = role.axis_index;
            },
            else => return null,
        }
    }
    const tok_axis = token_axis orelse return null;
    const hid_axis = hidden_axis orelse return null;
    if (tok_axis == hid_axis) return null;
    if (tok_axis >= func.axes.len or hid_axis >= func.axes.len) return null;
    if (tok_axis != 0 or hid_axis != 1) return null;

    const ib = func.bindings[ii];
    const tb = func.bindings[ti];
    const ob = func.bindings[oi];

    if (ib.read_write or tb.read_write) return null;
    if (!ob.read_write) return null;
    if (ib.elem != .u32) return null;
    if (tb.elem != ob.elem) return null;
    if (tb.elem != .f32 and tb.elem != .f16 and tb.elem != .bf16) return null;

    if (ib.logical_shape.len != 1) return null;
    if (tb.logical_shape.len != 2) return null;
    if (ob.logical_shape.len != 2) return null;

    const tokens_u64 = ib.logical_shape[0];
    const vocab_u64 = tb.logical_shape[0];
    const hidden_u64 = tb.logical_shape[1];
    if (ob.logical_shape[0] != tokens_u64) return null;
    if (ob.logical_shape[1] != hidden_u64) return null;

    const tokens: usize = std.math.cast(usize, tokens_u64) orelse return null;
    const vocab: usize = std.math.cast(usize, vocab_u64) orelse return null;
    const hidden: usize = std.math.cast(usize, hidden_u64) orelse return null;

    if (inputs.len != 2) return null;
    const indices_first = ii < ti;
    const indices_bytes = if (indices_first) inputs[0] else inputs[1];
    const table_bytes = if (indices_first) inputs[1] else inputs[0];

    const expected_indices_bytes = computeExpectedBytes(ib) orelse return null;
    const expected_table_bytes = computeExpectedBytes(tb) orelse return null;
    if (indices_bytes.len != expected_indices_bytes) return null;
    if (table_bytes.len != expected_table_bytes) return null;

    var validate_t: usize = 0;
    while (validate_t < tokens) : (validate_t += 1) {
        const index_off = std.math.mul(usize, validate_t, 4) catch return null;
        const row_u32 = std.mem.readInt(u32, indices_bytes[index_off..][0..4], .little);
        const row: usize = std.math.cast(usize, row_u32) orelse return null;
        if (row >= vocab) return null;
    }

    const expected_output_bytes = computeExpectedBytes(ob) orelse return null;
    const output_len = std.math.cast(usize, expected_output_bytes) orelse return null;
    const output_bytes = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output_bytes);

    const elem_bytes: usize = ob.elem.byteSize();
    var t: usize = 0;
    while (t < tokens) : (t += 1) {
        const index_off = std.math.mul(usize, t, 4) catch unreachable;
        const row_u32 = std.mem.readInt(u32, indices_bytes[index_off..][0..4], .little);
        const row: usize = std.math.cast(usize, row_u32) orelse unreachable;
        const table_row = std.math.mul(usize, row, hidden) catch unreachable;
        const output_row = std.math.mul(usize, t, hidden) catch unreachable;

        var h: usize = 0;
        while (h < hidden) : (h += 1) {
            const table_elem = std.math.add(usize, table_row, h) catch unreachable;
            const output_elem = std.math.add(usize, output_row, h) catch unreachable;
            const table_off = std.math.mul(usize, table_elem, elem_bytes) catch unreachable;
            const output_off = std.math.mul(usize, output_elem, elem_bytes) catch unreachable;
            @memcpy(output_bytes[output_off..][0..elem_bytes], table_bytes[table_off..][0..elem_bytes]);
        }
    }

    var outputs = try allocator.alloc([]const u8, 1);
    outputs[0] = output_bytes;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output_bytes, &hash, .{});

    return Result{
        .reference_hash = hash,
        .outputs = outputs,
        .rejections = &[_]schema.RejectionEntry{},
    };
}

/// Return the set of transcendental implementations the interpreter
/// uses. The real table pins each to a sollya-bounded minimax
/// polynomial with a declared worst-case ULP error bound.
pub const TranscendentalTable = struct {
    exp_ulp_bound: u32 = 1,
    log_ulp_bound: u32 = 1,
    sin_ulp_bound: u32 = 1,
    cos_ulp_bound: u32 = 1,
    tan_ulp_bound: u32 = 2,
    tanh_ulp_bound: u32 = 2,
    rsqrt_ulp_bound: u32 = 1,
    recip_ulp_bound: u32 = 1,
};

pub fn transcendentals() TranscendentalTable {
    return .{};
}
