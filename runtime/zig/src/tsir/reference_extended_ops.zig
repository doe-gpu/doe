const std = @import("std");
const scalar = @import("reference_scalar.zig");
const schema = @import("schema.zig");
const inputs_mod = @import("reference_inputs.zig");
const types = @import("reference_types.zig");

const InterpretError = types.InterpretError;
const Result = types.Result;
const computeExpectedBytes = scalar.computeExpectedBytes;
const readF32FromBytes = scalar.readF32FromBytes;
const writeF32AsElem = scalar.writeF32AsElem;
const countReadOnlyBindings = inputs_mod.countReadOnlyBindings;
const inputBytesForReadOnlyBinding = inputs_mod.inputBytesForReadOnlyBinding;

/// Detect the identity case and interpret it. Returns null when the
/// semantic is not shaped like identity, leaving the caller to fall
/// through to NotImplemented. Returns an allocated Result when the
/// semantic IS identity-shaped.
pub fn tryIdentity(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.reductions.len != 0) return null;
    if (func.collectives.len != 0) return null;

    // Exactly one read-only binding and one writable binding.
    var read_index: ?usize = null;
    var write_index: ?usize = null;
    for (func.bindings, 0..) |binding, i| {
        if (binding.read_write) {
            if (write_index != null) return null;
            write_index = i;
        } else {
            if (read_index != null) return null;
            read_index = i;
        }
    }
    const ri = read_index orelse return null;
    const wi = write_index orelse return null;
    const rb = func.bindings[ri];
    const wb = func.bindings[wi];

    // Shape and element type must match for identity.
    if (rb.elem != wb.elem) return null;
    if (rb.logical_shape.len != wb.logical_shape.len) return null;
    for (rb.logical_shape, wb.logical_shape) |r_dim, w_dim| {
        if (r_dim != w_dim) return null;
    }

    // Inputs[0] is the read binding's bytes. Copy it into a freshly
    // allocated output slot at outputs[0] (the write binding).
    if (inputs.len != 1) return null;
    const input_bytes = inputs[0];

    // Validate input buffer size matches declared shape × element size.
    // A wrong-sized input would silently produce a garbage hash; fall
    // through to NotImplemented so the caller sees a precise gap.
    const expected_bytes = computeExpectedBytes(rb) orelse return null;
    if (input_bytes.len != expected_bytes) return null;

    const output_bytes = try allocator.dupe(u8, input_bytes);
    errdefer allocator.free(output_bytes);

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

/// Detect and interpret the residual-add bootstrap-family case:
///   `output[i] = summand_a[i] + summand_b[i]` over a single hidden
///   axis. Shape this recognizer matches:
///   * one function, zero reductions, zero collectives, one axis
///   * exactly three bindings with declared roles:
///     `summand_a`, `summand_b`, `output`
///   * axis role is `hidden`
///   * `f32` element type across all three bindings (matches the live
///     emit_csl_semantic_ops.emitResidualPe wrapper)
///   * one-dimensional `logical_shape` matching across the three bindings
pub fn tryResidualAdd(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.collectives.len != 0) return null;
    if (func.reductions.len != 0) return null;
    if (func.bindings.len != 3) return null;
    if (func.axes.len != 1) return null;
    if (func.body.op != .residual_add) return null;
    if (func.body.binding_roles.len != 3) return null;
    if (func.body.axis_roles.len != 1) return null;

    if (func.body.axis_roles[0].role != .hidden) return null;

    var a_index: ?u32 = null;
    var b_index: ?u32 = null;
    var output_index: ?u32 = null;
    for (func.body.binding_roles) |role| {
        switch (role.role) {
            .summand_a => {
                if (a_index != null) return null;
                a_index = role.binding_index;
            },
            .summand_b => {
                if (b_index != null) return null;
                b_index = role.binding_index;
            },
            .output => {
                if (output_index != null) return null;
                output_index = role.binding_index;
            },
            else => return null,
        }
    }
    const ai = a_index orelse return null;
    const bi = b_index orelse return null;
    const oi = output_index orelse return null;
    if (ai >= func.bindings.len or bi >= func.bindings.len or oi >= func.bindings.len) return null;
    if (ai == bi or bi == oi or ai == oi) return null;

    const ab = func.bindings[ai];
    const bb = func.bindings[bi];
    const ob = func.bindings[oi];
    if (ab.read_write or bb.read_write) return null;
    if (!ob.read_write) return null;
    if (ab.elem != .f32 or bb.elem != .f32 or ob.elem != .f32) return null;
    if (ab.logical_shape.len != 1 or bb.logical_shape.len != 1 or ob.logical_shape.len != 1) return null;

    const len_u64 = ab.logical_shape[0];
    if (bb.logical_shape[0] != len_u64) return null;
    if (ob.logical_shape[0] != len_u64) return null;
    const len: usize = std.math.cast(usize, len_u64) orelse return null;

    if (inputs.len != countReadOnlyBindings(func)) return null;
    const a_bytes = inputBytesForReadOnlyBinding(func, inputs, ai) orelse return null;
    const b_bytes = inputBytesForReadOnlyBinding(func, inputs, bi) orelse return null;
    const expected_input_bytes = computeExpectedBytes(ab) orelse return null;
    if (a_bytes.len != expected_input_bytes) return null;
    if (b_bytes.len != expected_input_bytes) return null;

    const expected_output_bytes = computeExpectedBytes(ob) orelse return null;
    const output_len = std.math.cast(usize, expected_output_bytes) orelse return null;
    const output_bytes = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output_bytes);

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const a = readF32FromBytes(a_bytes, ab.elem, i);
        const b = readF32FromBytes(b_bytes, bb.elem, i);
        writeF32AsElem(output_bytes, i, a + b, ob.elem);
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

/// Detect and interpret the gated-activation family
/// (`gelu_gated`, `silu_gated`, `sigmoid_gated`):
///   `output[i] = act(gate[i]) * input[i]` where `act` is one of:
///     gelu    : tanh-approximation form Doppler's MLP block emits
///       inner = clamp(GELU_A * (x + GELU_B * x³), -15, 15)
///       gelu(x) = 0.5 * x * (1 + tanh(inner))
///       with `GELU_A = sqrt(2/π)` and `GELU_B = 0.044715`
///     silu    : `silu(x) = x / (1 + exp(z))` with `z = clamp(-x, -15, 15)`
///     sigmoid : `sigmoid(x) = 1 / (1 + exp(z))` with `z = clamp(-x, -15, 15)`
///   The clamps match the live emit body in
///   `emit_kernel_body_gated.zig` so the interpreter mirrors live
///   numerical behavior (algorithm-exact).
///
/// Shape this recognizer matches:
///   * one function, zero reductions, zero collectives, one axis
///   * exactly three bindings with declared roles: `gate`, `input`,
///     `output`
///   * axis role is `hidden`
///   * `f32` element type across all three bindings
///   * one-dimensional `logical_shape` matching across the three bindings
pub fn tryGated(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.collectives.len != 0) return null;
    if (func.reductions.len != 0) return null;
    if (func.bindings.len != 3) return null;
    if (func.axes.len != 1) return null;
    const gated_kind: enum { gelu, silu, sigmoid } = switch (func.body.op) {
        .gelu_gated => .gelu,
        .silu_gated => .silu,
        .sigmoid_gated => .sigmoid,
        else => return null,
    };
    if (func.body.binding_roles.len != 3) return null;
    if (func.body.axis_roles.len != 1) return null;

    if (func.body.axis_roles[0].role != .hidden) return null;

    var gate_index: ?u32 = null;
    var input_index: ?u32 = null;
    var output_index: ?u32 = null;
    for (func.body.binding_roles) |role| {
        switch (role.role) {
            .gate => {
                if (gate_index != null) return null;
                gate_index = role.binding_index;
            },
            .input => {
                if (input_index != null) return null;
                input_index = role.binding_index;
            },
            .output => {
                if (output_index != null) return null;
                output_index = role.binding_index;
            },
            else => return null,
        }
    }
    const gi = gate_index orelse return null;
    const ii = input_index orelse return null;
    const oi = output_index orelse return null;
    if (gi >= func.bindings.len or ii >= func.bindings.len or oi >= func.bindings.len) return null;
    if (gi == ii or ii == oi or gi == oi) return null;

    const gb = func.bindings[gi];
    const ib = func.bindings[ii];
    const ob = func.bindings[oi];
    if (gb.read_write or ib.read_write) return null;
    if (!ob.read_write) return null;
    if (gb.elem != .f32 or ib.elem != .f32 or ob.elem != .f32) return null;
    if (gb.logical_shape.len != 1 or ib.logical_shape.len != 1 or ob.logical_shape.len != 1) return null;

    const len_u64 = gb.logical_shape[0];
    if (ib.logical_shape[0] != len_u64) return null;
    if (ob.logical_shape[0] != len_u64) return null;
    const len: usize = std.math.cast(usize, len_u64) orelse return null;

    if (inputs.len != countReadOnlyBindings(func)) return null;
    const gate_bytes = inputBytesForReadOnlyBinding(func, inputs, gi) orelse return null;
    const input_bytes = inputBytesForReadOnlyBinding(func, inputs, ii) orelse return null;
    const expected_input_bytes = computeExpectedBytes(gb) orelse return null;
    if (gate_bytes.len != expected_input_bytes) return null;
    if (input_bytes.len != expected_input_bytes) return null;

    const expected_output_bytes = computeExpectedBytes(ob) orelse return null;
    const output_len = std.math.cast(usize, expected_output_bytes) orelse return null;
    const output_bytes = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output_bytes);

    const gelu_a: f32 = 0.7978845608028654;
    const gelu_b: f32 = 0.044715;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const x = readF32FromBytes(gate_bytes, gb.elem, i);
        const v = readF32FromBytes(input_bytes, ib.elem, i);
        const act_x: f32 = switch (gated_kind) {
            .gelu => blk: {
                var inner = gelu_a * (x + gelu_b * x * x * x);
                if (inner < -15.0) inner = -15.0;
                if (inner > 15.0) inner = 15.0;
                break :blk 0.5 * x * (1.0 + std.math.tanh(inner));
            },
            .silu => blk: {
                var z = -x;
                if (z < -15.0) z = -15.0;
                if (z > 15.0) z = 15.0;
                break :blk x / (1.0 + std.math.exp(z));
            },
            .sigmoid => blk: {
                var z = -x;
                if (z < -15.0) z = -15.0;
                if (z > 15.0) z = 15.0;
                break :blk 1.0 / (1.0 + std.math.exp(z));
            },
        };
        writeF32AsElem(output_bytes, i, act_x * v, ob.elem);
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

/// Detect and interpret the `attention_scores` body op.
///
/// Mirrors the CSL emit body in `emit_kernel_body_attention.zig`. Same
/// scope: bootstrap-canary surface only:
///   * softmax_mode = .two_pass_stable
///   * causal_mode  ∈ { .none, .causal, .sliding_window }
///   * has_softcap  = false
///   * scale_source = .literal_f32
///   * Q / K / V / output bindings declared via SemanticBindingRole
///   * f32 element type on every binding
///
/// Single-Q convention (decode-shape Q): query_pos = kv_len - 1.
/// `.causal` is then a structural no-op; `.sliding_window` masks
/// `k < kv_len - sliding_window_size`.
///
/// The math follows the same two-pass-stable softmax form the emit body
/// produces:
///   scores[k]  = (sum_d Q[d] * K[k, d]) * scale
///   m          = max_k scores[k]
///   weights[k] = exp(scores[k] - m); sum_e = sum_k weights[k]
///   O[d]       = sum_k V[k, d] * (weights[k] / sum_e)
///
/// This makes the canary's CSL hash comparable to a Zig-side numerical
/// reference for non-zero Q/K/V inputs, lifting the bootstrap-fixture
/// constraint that real attention closure required all-zero inputs.
pub fn tryAttentionScores(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.collectives.len != 0) return null;
    if (func.body.op != .attention_scores) return null;
    const attn = func.body.attention_scores orelse return null;
    if (attn.softmax_mode != .two_pass_stable) return null;
    if (attn.has_softcap) return null;
    if (attn.scale_source != .literal_f32) return null;
    const scale_f64 = attn.scale_literal_f32 orelse return null;
    const scale: f32 = @floatCast(scale_f64);
    var sliding_window_threshold: ?usize = null;
    switch (attn.causal_mode) {
        .none, .causal => {},
        .sliding_window => {
            const window = attn.sliding_window_size orelse return null;
            if (window == 0) return null;
            sliding_window_threshold = window;
        },
    }
    // Multi-Q (causal-prefill) shape: query_seq_len > 1 widens Q to
    // [query_seq_len * head_dim] and (for kv-axis-sharded) widens output
    // to [query_seq_len * (head_dim + 2)]. The bootstrap canary
    // interpreter covers the single-Q decode shape only; multi-Q is
    // exercised by emit-side unit tests until the host stitch oracle
    // for multi-Q lands.
    if (attn.query_seq_len) |qsl| {
        if (qsl > 1) return null;
    }

    if (inputs.len != countReadOnlyBindings(func)) return null;

    var query_index: ?u32 = null;
    var key_index: ?u32 = null;
    var value_index: ?u32 = null;
    var output_index: ?u32 = null;
    for (func.body.binding_roles) |role| {
        switch (role.role) {
            .query => {
                if (query_index != null) return null;
                query_index = role.binding_index;
            },
            .key => {
                if (key_index != null) return null;
                key_index = role.binding_index;
            },
            .value => {
                if (value_index != null) return null;
                value_index = role.binding_index;
            },
            .output => {
                if (output_index != null) return null;
                output_index = role.binding_index;
            },
            // Optional bindings (kv_len_buffer / page_table) are tolerated
            // here; the bootstrap-canary surface ignores them and lets
            // shapes drive kv_len.
            .kv_len_buffer, .page_table => {},
            else => return null,
        }
    }
    const qi = query_index orelse return null;
    const ki = key_index orelse return null;
    const vi = value_index orelse return null;
    const oi = output_index orelse return null;
    if (qi >= func.bindings.len or ki >= func.bindings.len or
        vi >= func.bindings.len or oi >= func.bindings.len) return null;

    const qb = func.bindings[qi];
    const kb = func.bindings[ki];
    const vb = func.bindings[vi];
    const ob = func.bindings[oi];
    if (qb.read_write or kb.read_write or vb.read_write) return null;
    if (!ob.read_write) return null;
    if (qb.elem != .f32 or kb.elem != .f32 or vb.elem != .f32 or ob.elem != .f32) return null;

    const head_dim_u32 = attn.head_dim;
    if (head_dim_u32 == 0) return null;
    const head_dim: usize = head_dim_u32;

    // Q is [head_dim]; K/V are [kv_len * head_dim]; O is [head_dim].
    if (qb.logical_shape.len != 1) return null;
    if (qb.logical_shape[0] != head_dim_u32) return null;
    if (ob.logical_shape.len != 1) return null;
    if (ob.logical_shape[0] != head_dim_u32) return null;
    if (kb.logical_shape.len < 1) return null;
    var k_total: u64 = 1;
    for (kb.logical_shape) |dim| k_total *= dim;
    if (k_total == 0 or k_total % head_dim_u32 != 0) return null;
    const kv_len_u64 = k_total / head_dim_u32;
    var v_total: u64 = 1;
    for (vb.logical_shape) |dim| v_total *= dim;
    if (v_total != k_total) return null;
    const kv_len: usize = std.math.cast(usize, kv_len_u64) orelse return null;
    if (kv_len == 0) return null;

    const q_bytes = inputBytesForReadOnlyBinding(func, inputs, qi) orelse return null;
    const k_bytes = inputBytesForReadOnlyBinding(func, inputs, ki) orelse return null;
    const v_bytes = inputBytesForReadOnlyBinding(func, inputs, vi) orelse return null;
    if (q_bytes.len != head_dim * 4) return null;
    if (k_bytes.len != kv_len * head_dim * 4) return null;
    if (v_bytes.len != kv_len * head_dim * 4) return null;

    const output_len = head_dim * 4;
    const output_bytes = try allocator.alloc(u8, output_len);
    errdefer allocator.free(output_bytes);

    var scores = try allocator.alloc(f32, kv_len);
    defer allocator.free(scores);

    // Pass 1: scores[k] = (Q · K[k]) * scale; track max. Apply causal /
    // sliding-window mask before the max comparison so masked-out slots
    // cannot win the running max (they go to -1e30 the same way the CSL
    // body's tail-mask does).
    const sentinel: f32 = -1.0e30;
    const sliding_start: usize = if (sliding_window_threshold) |window|
        if (kv_len > window) kv_len - window else 0
    else
        0;
    var max_score: f32 = -std.math.inf(f32);
    {
        var k: usize = 0;
        while (k < kv_len) : (k += 1) {
            var dot: f32 = 0.0;
            var d: usize = 0;
            while (d < head_dim) : (d += 1) {
                const q_val = readF32FromBytes(q_bytes, .f32, d);
                const k_val = readF32FromBytes(k_bytes, .f32, k * head_dim + d);
                dot += q_val * k_val;
            }
            var sc: f32 = dot * scale;
            switch (attn.causal_mode) {
                .none => {},
                .causal => {
                    // Single-Q convention: query_pos = kv_len - 1.
                    if (k > kv_len - 1) sc = sentinel;
                },
                .sliding_window => {
                    if (k < sliding_start) sc = sentinel;
                },
            }
            scores[k] = sc;
            if (sc > max_score) max_score = sc;
        }
    }

    // Pass 2: weights[k] = exp(scores[k] - max); sum.
    var sum_exp: f32 = 0.0;
    {
        var k: usize = 0;
        while (k < kv_len) : (k += 1) {
            const e = @exp(scores[k] - max_score);
            scores[k] = e;
            sum_exp += e;
        }
    }
    if (sum_exp == 0.0) return null;

    // Output: O[d] = sum_k V[k, d] * (weights[k] / sum_exp).
    {
        var d: usize = 0;
        while (d < head_dim) : (d += 1) {
            var acc: f32 = 0.0;
            var k: usize = 0;
            while (k < kv_len) : (k += 1) {
                const v_val = readF32FromBytes(v_bytes, .f32, k * head_dim + d);
                acc += v_val * (scores[k] / sum_exp);
            }
            writeF32AsElem(output_bytes, d, acc, .f32);
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

/// Detect and interpret the `l2_normalize` body op. Mirrors the CSL
/// emit at `emit_kernel_body_l2_normalize.zig`:
///   sq = sum_d input[d] * input[d]
///   inv = 1 / sqrt(sq + eps)
///   output[d] = input[d] * inv
/// Two read-only / read-write bindings (`input`, `output`); `f32`
/// elements; 1-D shape of length `body.hidden`.
pub fn tryL2Normalize(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.collectives.len != 0) return null;
    if (func.reductions.len != 0) return null;
    if (func.body.op != .l2_normalize) return null;
    const body = func.body.l2_normalize orelse return null;
    if (body.hidden == 0) return null;

    var input_index: ?u32 = null;
    var output_index: ?u32 = null;
    for (func.body.binding_roles) |role| {
        switch (role.role) {
            .input => {
                if (input_index != null) return null;
                input_index = role.binding_index;
            },
            .output => {
                if (output_index != null) return null;
                output_index = role.binding_index;
            },
            else => return null,
        }
    }
    const ii = input_index orelse return null;
    const oi = output_index orelse return null;
    if (ii >= func.bindings.len or oi >= func.bindings.len) return null;
    const ib = func.bindings[ii];
    const ob = func.bindings[oi];
    if (ib.read_write or !ob.read_write) return null;
    if (ib.elem != .f32 or ob.elem != .f32) return null;

    const hidden: usize = body.hidden;
    if (inputs.len != countReadOnlyBindings(func)) return null;
    const in_bytes = inputBytesForReadOnlyBinding(func, inputs, ii) orelse return null;
    if (in_bytes.len != hidden * 4) return null;

    const output_bytes = try allocator.alloc(u8, hidden * 4);
    errdefer allocator.free(output_bytes);

    var sq: f32 = 0.0;
    {
        var d: usize = 0;
        while (d < hidden) : (d += 1) {
            const v = readF32FromBytes(in_bytes, .f32, d);
            sq += v * v;
        }
    }
    const inv_norm: f32 = 1.0 / std.math.sqrt(sq + body.eps);
    {
        var d: usize = 0;
        while (d < hidden) : (d += 1) {
            const v = readF32FromBytes(in_bytes, .f32, d);
            writeF32AsElem(output_bytes, d, v * inv_norm, .f32);
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

/// Detect and interpret `conv1d_depthwise`. Mirrors
/// `emit_kernel_body_conv1d.zig`: causal-pad depthwise conv, optional
/// per-channel bias. Inputs are row-major `[token, channel]`.
pub fn tryConv1DDepthwise(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.collectives.len != 0) return null;
    if (func.reductions.len != 0) return null;
    if (func.body.op != .conv1d_depthwise) return null;
    const body = func.body.conv1d_depthwise orelse return null;
    if (body.channels == 0 or body.kernel_size == 0) return null;

    var in_idx: ?u32 = null;
    var w_idx: ?u32 = null;
    var b_idx: ?u32 = null;
    var out_idx: ?u32 = null;
    for (func.body.binding_roles) |role| {
        switch (role.role) {
            .input => in_idx = role.binding_index,
            .weight => w_idx = role.binding_index,
            .bias => b_idx = role.binding_index,
            .output => out_idx = role.binding_index,
            else => return null,
        }
    }
    const ii = in_idx orelse return null;
    const wi = w_idx orelse return null;
    const oi = out_idx orelse return null;
    if (body.has_bias and b_idx == null) return null;
    if (!body.has_bias and b_idx != null) return null;

    const ib = func.bindings[ii];
    const wb = func.bindings[wi];
    const ob = func.bindings[oi];
    if (ib.read_write or wb.read_write or !ob.read_write) return null;
    if (ib.elem != .f32 or wb.elem != .f32 or ob.elem != .f32) return null;

    if (inputs.len != countReadOnlyBindings(func)) return null;
    const in_bytes = inputBytesForReadOnlyBinding(func, inputs, ii) orelse return null;
    const weight_bytes = inputBytesForReadOnlyBinding(func, inputs, wi) orelse return null;
    const bias_bytes_opt: ?[]const u8 = if (b_idx) |bi|
        inputBytesForReadOnlyBinding(func, inputs, bi)
    else
        null;
    if (body.has_bias and bias_bytes_opt == null) return null;

    const channels: usize = body.channels;
    const kernel_size: usize = body.kernel_size;
    if (in_bytes.len % (channels * 4) != 0) return null;
    const num_tokens: usize = in_bytes.len / (channels * 4);
    if (num_tokens == 0) return null;
    if (weight_bytes.len != channels * kernel_size * 4) return null;
    if (bias_bytes_opt) |bb| {
        if (bb.len != channels * 4) return null;
    }

    const output_bytes = try allocator.alloc(u8, num_tokens * channels * 4);
    errdefer allocator.free(output_bytes);
    var t: usize = 0;
    while (t < num_tokens) : (t += 1) {
        var c: usize = 0;
        while (c < channels) : (c += 1) {
            var acc: f32 = if (bias_bytes_opt) |bb|
                readF32FromBytes(bb, .f32, c)
            else
                0.0;
            var k: usize = 0;
            while (k < kernel_size) : (k += 1) {
                const t_in: isize = @as(isize, @intCast(t)) - @as(isize, @intCast(kernel_size - 1 - k));
                if (t_in < 0) continue;
                const t_in_u: usize = @intCast(t_in);
                const v = readF32FromBytes(in_bytes, .f32, t_in_u * channels + c);
                const w = readF32FromBytes(weight_bytes, .f32, c * kernel_size + k);
                acc += v * w;
            }
            writeF32AsElem(output_bytes, t * channels + c, acc, .f32);
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

/// Detect and interpret `linear_attention` (gated DeltaNet, single-Q
/// shared-norm form). Mirrors `emit_kernel_body_linear_attention.zig`.
/// `linear_state` is read-write; the interpreter reads its prior bytes
/// from the corresponding position in `inputs[]`, computes the new
/// state, and emits TWO output buffers in declaration order:
/// `[new_state, output]`.
pub fn tryLinearAttention(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.collectives.len != 0) return null;
    if (func.reductions.len != 0) return null;
    if (func.body.op != .linear_attention) return null;
    const body = func.body.linear_attention orelse return null;
    if (body.norm_mode != .shared or body.has_dt_bias) return null;
    if (body.key_dim == 0 or body.value_dim == 0) return null;

    var q_idx: ?u32 = null;
    var k_idx: ?u32 = null;
    var v_idx: ?u32 = null;
    var g_idx: ?u32 = null;
    var s_idx: ?u32 = null;
    var o_idx: ?u32 = null;
    for (func.body.binding_roles) |role| {
        switch (role.role) {
            .query => q_idx = role.binding_index,
            .key => k_idx = role.binding_index,
            .value => v_idx = role.binding_index,
            .gate => g_idx = role.binding_index,
            .linear_state => s_idx = role.binding_index,
            .output => o_idx = role.binding_index,
            else => return null,
        }
    }
    const qi = q_idx orelse return null;
    const ki = k_idx orelse return null;
    const vi = v_idx orelse return null;
    const gi = g_idx orelse return null;
    const si = s_idx orelse return null;
    const oi = o_idx orelse return null;

    const qb = func.bindings[qi];
    const kb = func.bindings[ki];
    const vb = func.bindings[vi];
    const gb = func.bindings[gi];
    const sb = func.bindings[si];
    const ob = func.bindings[oi];
    if (qb.read_write or kb.read_write or vb.read_write or gb.read_write) return null;
    if (!sb.read_write or !ob.read_write) return null;
    if (qb.elem != .f32 or kb.elem != .f32 or vb.elem != .f32 or gb.elem != .f32 or sb.elem != .f32 or ob.elem != .f32) return null;

    const value_dim: usize = body.value_dim;
    const key_dim: usize = body.key_dim;
    if (inputs.len != countReadOnlyBindings(func)) return null;

    const q_bytes = inputBytesForReadOnlyBinding(func, inputs, qi) orelse return null;
    const k_bytes = inputBytesForReadOnlyBinding(func, inputs, ki) orelse return null;
    const v_bytes = inputBytesForReadOnlyBinding(func, inputs, vi) orelse return null;
    const g_bytes = inputBytesForReadOnlyBinding(func, inputs, gi) orelse return null;
    const s_bytes_in = inputBytesForReadOnlyBinding(func, inputs, si) orelse return null;
    if (q_bytes.len != value_dim * 4) return null;
    if (k_bytes.len != key_dim * 4) return null;
    if (v_bytes.len != key_dim * 4) return null;
    if (g_bytes.len != value_dim * 4) return null;
    if (s_bytes_in.len != value_dim * key_dim * 4) return null;

    // Caller pins a_log via the realization side; the bootstrap-canary
    // interpreter uses a fixed default of A_log=0.5 to keep alpha in a
    // numerically friendly range. Any real lowering that pins a_log
    // through compile params can be checked by hashing the output for
    // a known a_log value.
    const a_log: f32 = 0.5;
    const alpha: f32 = 1.0 - std.math.exp(-a_log);
    const decay: f32 = 1.0 - alpha;

    const new_state = try allocator.alloc(u8, value_dim * key_dim * 4);
    errdefer allocator.free(new_state);
    @memcpy(new_state, s_bytes_in);

    {
        var d: usize = 0;
        while (d < value_dim) : (d += 1) {
            var prev_dot: f32 = 0.0;
            var k: usize = 0;
            while (k < key_dim) : (k += 1) {
                const s = readF32FromBytes(new_state, .f32, d * key_dim + k);
                const k_in = readF32FromBytes(k_bytes, .f32, k);
                prev_dot += s * k_in;
            }
            const q_d = readF32FromBytes(q_bytes, .f32, d);
            const correction = q_d - prev_dot;
            const scaled = alpha * correction;
            k = 0;
            while (k < key_dim) : (k += 1) {
                const k_in = readF32FromBytes(k_bytes, .f32, k);
                const idx = d * key_dim + k;
                const prev_state = readF32FromBytes(new_state, .f32, idx);
                const delta = scaled * k_in;
                writeF32AsElem(new_state, idx, decay * prev_state + delta, .f32);
            }
        }
    }

    const output_bytes = try allocator.alloc(u8, value_dim * 4);
    errdefer allocator.free(output_bytes);
    {
        var d: usize = 0;
        while (d < value_dim) : (d += 1) {
            var acc: f32 = 0.0;
            var k: usize = 0;
            while (k < key_dim) : (k += 1) {
                const s = readF32FromBytes(new_state, .f32, d * key_dim + k);
                const v = readF32FromBytes(v_bytes, .f32, k);
                acc += s * v;
            }
            const g_d = readF32FromBytes(g_bytes, .f32, d);
            const sigmoid_g: f32 = 1.0 / (1.0 + std.math.exp(-g_d));
            const q_d = readF32FromBytes(q_bytes, .f32, d);
            writeF32AsElem(output_bytes, d, acc + sigmoid_g * q_d, .f32);
        }
    }

    var outputs = try allocator.alloc([]const u8, 2);
    outputs[0] = new_state;
    outputs[1] = output_bytes;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(new_state);
    hasher.update(output_bytes);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    return Result{
        .reference_hash = hash,
        .outputs = outputs,
        .rejections = &[_]schema.RejectionEntry{},
    };
}
