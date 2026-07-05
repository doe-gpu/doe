const std = @import("std");
const scalar = @import("reference_scalar.zig");
const schema = @import("schema.zig");
const types = @import("reference_types.zig");

const InterpretError = types.InterpretError;
const Result = types.Result;
const combineF32 = scalar.combineF32;
const computeExpectedBytes = scalar.computeExpectedBytes;
const readF32FromBytes = scalar.readF32FromBytes;
const reductionIdentityF32 = scalar.reductionIdentityF32;
const writeF32AsElem = scalar.writeF32AsElem;

/// Detect and interpret simple one-binding reductions. Phase A coverage:
///   * 2 bindings (one read-only input, one read-write output).
///   * 1 reduction with `f32` accumulation; `sum`, `product`, `min`, or
///     `max` op; `NaN/Inf = propagate`.
///   * Associativity: `strict_ordered` (left-fold) or
///     `associative_allowed` (tree shape from the matching
///     Realization reduction node; `.linear` / `.ring` single-PE-
///     identical, `.binomial` pairwise).
///   * Ranks 1, 2, 3, and 4+ (generic N-D fallback). Binomial fold is
///     supported for ranks 1, 2, 3; rank 4+ rejects binomial and
///     returns null so the caller can emit `NotImplemented`.
///   * Input dtypes `{f32, f16, bf16}` via upcast to f32; output dtypes
///     `{f32, f16, bf16}` via downcast from the f32 accumulator.
///
/// Anything outside this envelope falls through to `NotImplemented` so
/// the oracle never silently honors a reduction class it has not yet
/// implemented.
pub fn trySimpleReduction(
    allocator: std.mem.Allocator,
    semantic: schema.Semantic,
    realization: schema.Realization,
    inputs: []const []const u8,
) InterpretError!?Result {
    if (semantic.functions.len != 1) return null;
    const func = semantic.functions[0];
    if (func.bindings.len != 2) return null;
    if (func.reductions.len != 1) return null;
    if (func.collectives.len != 0) return null;

    const reduction = func.reductions[0];
    if (reduction.contract.accumulation != .f32) return null;
    // Associativity dispatch:
    //   strict_ordered     → tree shape is always linear (left-fold).
    //   associative_allowed → require a declared Realization tree
    //                        shape. `.linear`, `.ring`, and `.binomial`
    //                        are all accepted; the reference oracle
    //                        runs on a single PE, so `.ring` is
    //                        fold-order-identical to `.linear` here
    //                        (the distinction is fabric topology,
    //                        which a single-PE interpreter cannot
    //                        exercise). `.binomial` pairwise fold is
    //                        supported for ranks 1–3; rank 4+ rejects
    //                        binomial and falls through.
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
    // Per-rank branches own axis validation.

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
    if (reduction.target_binding != wi) return null;

    const rb = func.bindings[ri];
    const wb = func.bindings[wi];

    // Phase A input dtypes: f32 natively, f16 and bf16 upcast to f32
    // per the declared `NumericalContract.accumulation = .f32`. Output
    // dtypes: f32 natively, or f16 / bf16 via downcast from the f32
    // accumulator. Integer dtypes remain future work.
    if (rb.elem != .f32 and rb.elem != .f16 and rb.elem != .bf16) return null;
    if (wb.elem != .f32 and wb.elem != .f16 and wb.elem != .bf16) return null;

    const identity = reductionIdentityF32(reduction.op);
    const rank = rb.logical_shape.len;

    // 1-D input, scalar output.
    if (rank == 1) {
        if (wb.logical_shape.len != 1 or wb.logical_shape[0] != 1) return null;
        if (reduction.axis != 0) return null;

        const n_u64 = rb.logical_shape[0];
        const n: usize = std.math.cast(usize, n_u64) orelse return null;

        if (n == 0) {
            if (inputs.len != 0 and (inputs.len != 1 or inputs[0].len != 0)) return null;
            return try emitScalarFromF32(allocator, identity, wb.elem);
        }

        if (inputs.len != 1) return null;
        const input_bytes = inputs[0];
        const expected_bytes = computeExpectedBytes(rb) orelse return null;
        if (input_bytes.len != expected_bytes) return null;

        switch (effective_tree_shape) {
            .linear, .ring => {
                // On a single-PE reference, ring == linear bit-for-bit.
                var acc: f32 = identity;
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const val = readF32FromBytes(input_bytes, rb.elem, i);
                    acc = combineF32(reduction.op, acc, val);
                }
                return try emitScalarFromF32(allocator, acc, wb.elem);
            },
            .binomial => {
                // Gather all N values then pairwise-fold, passing
                // through any odd leftover to the next level. Result
                // is the op applied in a power-of-two-shaped tree
                // rather than left-associatively; on
                // non-associative floating-point it can differ bit-
                // for-bit from the linear fold, which is exactly the
                // reason `algorithm_exact` pins `tree_shape` as a
                // declared invariant.
                const vals = try allocator.alloc(f32, n);
                defer allocator.free(vals);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    vals[i] = readF32FromBytes(input_bytes, rb.elem, i);
                }
                var count: usize = n;
                while (count > 1) {
                    var new_count: usize = 0;
                    var idx: usize = 0;
                    while (idx < count) : (idx += 2) {
                        if (idx + 1 < count) {
                            vals[new_count] = combineF32(reduction.op, vals[idx], vals[idx + 1]);
                        } else {
                            vals[new_count] = vals[idx];
                        }
                        new_count += 1;
                    }
                    count = new_count;
                }
                return try emitScalarFromF32(allocator, vals[0], wb.elem);
            },
        }
    }

    // 2-D input, 1-D output along the non-reduced axis.
    if (rank == 2) {
        if (reduction.axis >= 2) return null;
        const m_u64 = rb.logical_shape[0];
        const n_u64 = rb.logical_shape[1];
        const m: usize = std.math.cast(usize, m_u64) orelse return null;
        const n: usize = std.math.cast(usize, n_u64) orelse return null;
        const non_reduced_u64: u64 = if (reduction.axis == 0) n_u64 else m_u64;
        if (wb.logical_shape.len != 1 or wb.logical_shape[0] != non_reduced_u64) return null;
        const non_reduced: usize = if (reduction.axis == 0) n else m;
        const reduce_len: usize = if (reduction.axis == 0) m else n;

        const expected_bytes = computeExpectedBytes(rb) orelse return null;
        if (inputs.len != 1) return null;
        const input_bytes = inputs[0];
        if (input_bytes.len != expected_bytes) return null;

        const out_elem_bytes: usize = wb.elem.byteSize();
        const output_bytes = try allocator.alloc(u8, non_reduced * out_elem_bytes);
        errdefer allocator.free(output_bytes);

        // Per-output scratch for binomial fold. Allocated once,
        // reused across output positions to keep the hot loop
        // alloc-free.
        var scratch: ?[]f32 = null;
        defer if (scratch) |s| allocator.free(s);
        if (effective_tree_shape == .binomial and reduce_len > 0) {
            scratch = try allocator.alloc(f32, reduce_len);
        }

        var out_i: usize = 0;
        while (out_i < non_reduced) : (out_i += 1) {
            if (effective_tree_shape == .binomial) {
                if (reduce_len == 0) {
                    writeF32AsElem(output_bytes, out_i, identity, wb.elem);
                    continue;
                }
                const vals = scratch.?;
                var r_i: usize = 0;
                while (r_i < reduce_len) : (r_i += 1) {
                    const flat_idx: usize = if (reduction.axis == 0)
                        r_i * n + out_i
                    else
                        out_i * n + r_i;
                    vals[r_i] = readF32FromBytes(input_bytes, rb.elem, flat_idx);
                }
                var count: usize = reduce_len;
                while (count > 1) {
                    var new_count: usize = 0;
                    var idx: usize = 0;
                    while (idx < count) : (idx += 2) {
                        if (idx + 1 < count) {
                            vals[new_count] = combineF32(reduction.op, vals[idx], vals[idx + 1]);
                        } else {
                            vals[new_count] = vals[idx];
                        }
                        new_count += 1;
                    }
                    count = new_count;
                }
                writeF32AsElem(output_bytes, out_i, vals[0], wb.elem);
            } else {
                // Linear / ring left-fold (bit-identical on single PE).
                var acc: f32 = identity;
                var r_i: usize = 0;
                while (r_i < reduce_len) : (r_i += 1) {
                    const flat_idx: usize = if (reduction.axis == 0)
                        r_i * n + out_i
                    else
                        out_i * n + r_i;
                    const val = readF32FromBytes(input_bytes, rb.elem, flat_idx);
                    acc = combineF32(reduction.op, acc, val);
                }
                writeF32AsElem(output_bytes, out_i, acc, wb.elem);
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

    // 3-D input, 2-D output along the two non-reduced axes.
    if (rank == 3) {
        if (reduction.axis >= 3) return null;
        const axis = reduction.axis;
        const a_u64 = rb.logical_shape[0];
        const b_u64 = rb.logical_shape[1];
        const c_u64 = rb.logical_shape[2];
        const a_us: usize = std.math.cast(usize, a_u64) orelse return null;
        const b_us: usize = std.math.cast(usize, b_u64) orelse return null;
        const c_us: usize = std.math.cast(usize, c_u64) orelse return null;

        // Output shape drops the reduced axis; row-major ordering is
        // preserved for the surviving dims.
        const out_dim0_u64: u64 = if (axis == 0) b_u64 else a_u64;
        const out_dim1_u64: u64 = if (axis == 2) b_u64 else c_u64;
        if (wb.logical_shape.len != 2) return null;
        if (wb.logical_shape[0] != out_dim0_u64) return null;
        if (wb.logical_shape[1] != out_dim1_u64) return null;

        const out_dim0: usize = if (axis == 0) b_us else a_us;
        const out_dim1: usize = if (axis == 2) b_us else c_us;
        const non_reduced: usize = out_dim0 * out_dim1;
        const reduce_len: usize = switch (axis) {
            0 => a_us,
            1 => b_us,
            2 => c_us,
            else => unreachable,
        };

        const expected_bytes = computeExpectedBytes(rb) orelse return null;
        if (inputs.len != 1) return null;
        const input_bytes = inputs[0];
        if (input_bytes.len != expected_bytes) return null;

        const out_elem_bytes: usize = wb.elem.byteSize();
        const output_bytes = try allocator.alloc(u8, non_reduced * out_elem_bytes);
        errdefer allocator.free(output_bytes);

        // Scratch buffer for binomial fold (reused across out_i).
        var scratch: ?[]f32 = null;
        defer if (scratch) |s| allocator.free(s);
        if (effective_tree_shape == .binomial and reduce_len > 0) {
            scratch = try allocator.alloc(f32, reduce_len);
        }

        var out_i: usize = 0;
        while (out_i < non_reduced) : (out_i += 1) {
            const d0 = out_i / out_dim1;
            const d1 = out_i % out_dim1;
            if (effective_tree_shape == .binomial) {
                if (reduce_len == 0) {
                    writeF32AsElem(output_bytes, out_i, identity, wb.elem);
                    continue;
                }
                const vals = scratch.?;
                var r: usize = 0;
                while (r < reduce_len) : (r += 1) {
                    const flat: usize = switch (axis) {
                        0 => r * b_us * c_us + d0 * c_us + d1,
                        1 => d0 * b_us * c_us + r * c_us + d1,
                        2 => d0 * b_us * c_us + d1 * c_us + r,
                        else => unreachable,
                    };
                    vals[r] = readF32FromBytes(input_bytes, rb.elem, flat);
                }
                var count: usize = reduce_len;
                while (count > 1) {
                    var new_count: usize = 0;
                    var idx: usize = 0;
                    while (idx < count) : (idx += 2) {
                        if (idx + 1 < count) {
                            vals[new_count] = combineF32(reduction.op, vals[idx], vals[idx + 1]);
                        } else {
                            vals[new_count] = vals[idx];
                        }
                        new_count += 1;
                    }
                    count = new_count;
                }
                writeF32AsElem(output_bytes, out_i, vals[0], wb.elem);
            } else {
                var acc: f32 = identity;
                var r: usize = 0;
                while (r < reduce_len) : (r += 1) {
                    // Row-major input: [a, b, c] → flat = a*B*C + b*C + c.
                    const flat: usize = switch (axis) {
                        0 => r * b_us * c_us + d0 * c_us + d1,
                        1 => d0 * b_us * c_us + r * c_us + d1,
                        2 => d0 * b_us * c_us + d1 * c_us + r,
                        else => unreachable,
                    };
                    const val = readF32FromBytes(input_bytes, rb.elem, flat);
                    acc = combineF32(reduction.op, acc, val);
                }
                writeF32AsElem(output_bytes, out_i, acc, wb.elem);
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

    // Rank 4+ fallback: generic N-D reduction. Same row-major layout,
    // same accumulation contract, same op dispatch — the difference is
    // the non-reduced iteration uses an odometer instead of explicit
    // nested loops so any rank works without another per-rank branch.
    if (rank >= 4) {
        if (effective_tree_shape == .binomial) return null;
        const axis = reduction.axis;
        if (axis >= rank) return null;

        // Validate output shape: rank-1, skipping the reduced axis.
        if (wb.logical_shape.len != rank - 1) return null;
        {
            var src_idx: usize = 0;
            for (wb.logical_shape) |w_dim| {
                if (src_idx == axis) src_idx += 1;
                if (src_idx >= rank) return null;
                if (rb.logical_shape[src_idx] != w_dim) return null;
                src_idx += 1;
            }
        }

        // Row-major input strides.
        const shape_us = try allocator.alloc(usize, rank);
        defer allocator.free(shape_us);
        for (rb.logical_shape, 0..) |d, i| {
            shape_us[i] = std.math.cast(usize, d) orelse return null;
        }
        const strides = try allocator.alloc(usize, rank);
        defer allocator.free(strides);
        strides[rank - 1] = 1;
        {
            var i: usize = rank - 1;
            while (i > 0) : (i -= 1) {
                strides[i - 1] = strides[i] * shape_us[i];
            }
        }

        var non_reduced: usize = 1;
        for (shape_us, 0..) |d, i| {
            if (i == axis) continue;
            non_reduced *= d;
        }
        const reduce_len: usize = shape_us[axis];
        const axis_stride: usize = strides[axis];

        const expected_bytes = computeExpectedBytes(rb) orelse return null;
        if (inputs.len != 1) return null;
        const input_bytes = inputs[0];
        if (input_bytes.len != expected_bytes) return null;

        const out_elem_bytes: usize = wb.elem.byteSize();
        const output_bytes = try allocator.alloc(u8, non_reduced * out_elem_bytes);
        errdefer allocator.free(output_bytes);

        const out_rank: usize = rank - 1;
        const out_coords = try allocator.alloc(usize, out_rank);
        defer allocator.free(out_coords);
        for (out_coords) |*c| c.* = 0;

        var out_linear: usize = 0;
        iter: while (true) {
            // Base offset in input from current out_coords.
            var base_offset: usize = 0;
            for (out_coords, 0..) |c, out_pos| {
                const in_dim_idx: usize = if (out_pos < axis) out_pos else out_pos + 1;
                base_offset += c * strides[in_dim_idx];
            }

            var acc: f32 = identity;
            var r: usize = 0;
            while (r < reduce_len) : (r += 1) {
                const flat = base_offset + r * axis_stride;
                const val = readF32FromBytes(input_bytes, rb.elem, flat);
                acc = combineF32(reduction.op, acc, val);
            }
            writeF32AsElem(output_bytes, out_linear, acc, wb.elem);

            out_linear += 1;
            if (out_linear >= non_reduced) break;

            // Increment odometer from rightmost out_pos, carrying left.
            var carry_pos: usize = out_rank - 1;
            while (true) {
                out_coords[carry_pos] += 1;
                const limit_u64 = wb.logical_shape[carry_pos];
                const limit: usize = std.math.cast(usize, limit_u64) orelse return null;
                if (out_coords[carry_pos] < limit) break;
                out_coords[carry_pos] = 0;
                if (carry_pos == 0) break :iter;
                carry_pos -= 1;
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

    return null;
}

/// Emit a single scalar f32 as the declared output dtype. Used by the
/// rank-1 reduction path; the rank-2 path emits a vector element-wise
/// through `writeF32AsElem` directly.
fn emitScalarFromF32(
    allocator: std.mem.Allocator,
    acc: f32,
    elem: schema.ScalarKind,
) InterpretError!Result {
    const out_bytes_len: usize = elem.byteSize();
    const output_bytes = try allocator.alloc(u8, out_bytes_len);
    errdefer allocator.free(output_bytes);
    writeF32AsElem(output_bytes, 0, acc, elem);

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
