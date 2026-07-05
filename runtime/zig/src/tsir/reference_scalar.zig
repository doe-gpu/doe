const std = @import("std");
const schema = @import("schema.zig");

/// Identity element for a reduction op in f32. Left-folding any
/// sequence starting from this value must yield the same result as
/// folding the sequence alone.
pub fn reductionIdentityF32(op: schema.ReductionOp) f32 {
    return switch (op) {
        .sum => 0.0,
        .product => 1.0,
        .min => std.math.inf(f32),
        .max => -std.math.inf(f32),
        // softmax_stable is a compound (max-then-sum-exp) op; it does
        // not have a left-fold identity and must not be dispatched
        // through the scalar simple-fold helpers. Attention semantic
        // evaluation happens outside this path.
        .softmax_stable => unreachable,
    };
}

/// Combine `acc` with `val` under the declared reduction op in f32.
/// `std.math.min` / `std.math.max` honor IEEE-754 min/max semantics
/// including NaN propagation per the `NanInfPolicy.propagate` contract.
pub fn combineF32(op: schema.ReductionOp, acc: f32, val: f32) f32 {
    return switch (op) {
        .sum => acc + val,
        .product => acc * val,
        .min => @min(acc, val),
        .max => @max(acc, val),
        // See `reductionIdentityF32` - softmax_stable is handled
        // outside the scalar simple-fold path.
        .softmax_stable => unreachable,
    };
}

/// Read one f32 value from a byte buffer at `elem_idx`, upcasting from
/// the declared element type.
pub fn readF32FromBytes(
    bytes: []const u8,
    elem: schema.ScalarKind,
    elem_idx: usize,
) f32 {
    switch (elem) {
        .f32 => {
            const word = std.mem.readInt(u32, bytes[elem_idx * 4 ..][0..4], .little);
            return @bitCast(word);
        },
        .f16 => {
            const word = std.mem.readInt(u16, bytes[elem_idx * 2 ..][0..2], .little);
            const v16: f16 = @bitCast(word);
            return @floatCast(v16);
        },
        .bf16 => {
            const word = std.mem.readInt(u16, bytes[elem_idx * 2 ..][0..2], .little);
            const f32_bits: u32 = @as(u32, word) << 16;
            return @bitCast(f32_bits);
        },
        else => unreachable,
    }
}

/// Write one f32 value into `bytes` at element index `elem_idx`,
/// downcasting to the declared output dtype.
pub fn writeF32AsElem(
    bytes: []u8,
    elem_idx: usize,
    val: f32,
    elem: schema.ScalarKind,
) void {
    switch (elem) {
        .f32 => {
            const bits: u32 = @bitCast(val);
            std.mem.writeInt(u32, bytes[elem_idx * 4 ..][0..4], bits, .little);
        },
        .f16 => {
            const v16: f16 = @floatCast(val);
            const bits: u16 = @bitCast(v16);
            std.mem.writeInt(u16, bytes[elem_idx * 2 ..][0..2], bits, .little);
        },
        .bf16 => {
            const bits: u16 = f32ToBf16Rne(val);
            std.mem.writeInt(u16, bytes[elem_idx * 2 ..][0..2], bits, .little);
        },
        else => unreachable,
    }
}

/// Convert f32 to bf16 via round-to-nearest-even on the u32 bit pattern.
pub fn f32ToBf16Rne(val: f32) u16 {
    const bits: u32 = @bitCast(val);
    const exp: u32 = (bits >> 23) & 0xff;
    const mantissa: u32 = bits & 0x7fffff;
    if (exp == 0xff and mantissa != 0) {
        // NaN: take the high 16 bits and ensure the quiet-NaN mantissa
        // bit is set. This avoids turning NaN into Inf via the bias.
        return @as(u16, @intCast((bits >> 16) | 0x40));
    }
    const lsb: u32 = (bits >> 16) & 1;
    const rounding_bias: u32 = 0x7fff + lsb;
    const rounded: u32 = bits +% rounding_bias;
    return @as(u16, @intCast(rounded >> 16));
}

/// Compute the expected total byte count for a buffer binding from its
/// declared shape and element type.
pub fn computeExpectedBytes(binding: schema.BufferBinding) ?u64 {
    var elems: u64 = 1;
    for (binding.logical_shape) |dim| {
        if (dim == 0) return 0;
        elems = std.math.mul(u64, elems, dim) catch return null;
    }
    return std.math.mul(u64, elems, @as(u64, binding.elem.byteSize())) catch null;
}
