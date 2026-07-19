// emit_dtype_routing.zig — Track-2 lane / dtype routing helpers shared
// across the TSIR emit-body modules.
//
// The widening from a hardcoded `.f32` lane to a manifest-declared
// compute dtype is centralized here so each per-op module
// (`emit_kernel_body.zig`, `emit_kernel_body_kv.zig`,
// `emit_kernel_body_attention.zig`, …) can call into a single source
// of truth for:
//
//   - cslElemName / wgslElemName: dtype → source-level type spelling
//   - isSupportedComputeElem / requireSupportedComputeElem: lane gate
//   - writeWgslF16Enable: emit `enable f16;` directive when needed
//
// CSL natively supports `f16` arithmetic on WSE-3, so the emit-side
// switch is a string-name routing only — no per-op reduction or
// accumulator widening. The transcendental-up-cast carve-out
// (`sqrt_nr` for f16) lives in the calling op since it touches body
// generation; this module only owns the routing primitives.

const std = @import("std");
const schema = @import("schema.zig");

/// Map a TSIR ScalarKind to the CSL source-level type spelling.
pub fn cslElemName(elem: schema.ScalarKind) []const u8 {
    return switch (elem) {
        .f32 => "f32",
        .f16 => "f16",
        .bf16 => "bf16",
        .i32 => "i32",
        .u32 => "u32",
    };
}

/// WGSL counterpart of `cslElemName`. WGSL `f16` requires the
/// `enable f16;` directive at the top of the shader; emitters that
/// route any binding through `f16` must call `writeWgslF16Enable`
/// before any other source bytes.
pub fn wgslElemName(elem: schema.ScalarKind) []const u8 {
    return switch (elem) {
        .f32 => "f32",
        .f16 => "f16",
        .bf16 => "f16", // WGSL has no bf16; bf16 manifests are rejected at requireSupportedComputeElem
        .i32 => "i32",
        .u32 => "u32",
    };
}

/// True if `elem` is a 16- or 32-bit float that the f16/f32 lanes
/// admit as the activation/compute dtype. Used at emit entry to fail
/// closed for unsupported compute dtypes (bf16/int8/etc.) before the
/// per-binding requireElem assertions run.
pub fn isSupportedComputeElem(elem: schema.ScalarKind) bool {
    return switch (elem) {
        .f32, .f16 => true,
        .bf16, .i32, .u32 => false,
    };
}

/// Reject compute dtypes the lowering does not yet support. Per-op
/// emit functions call this with the lane dtype (derived from a
/// canonical binding) before producing any source bytes.
pub fn requireSupportedComputeElem(elem: schema.ScalarKind) error{UnsupportedScalarKind}!void {
    if (!isSupportedComputeElem(elem)) return error.UnsupportedScalarKind;
}

/// Emit the `enable f16;` WGSL directive when the lane dtype is f16.
/// No-op for f32 to keep f32 shader bytes byte-identical to the
/// pre-Track-2 baseline.
pub fn writeWgslF16Enable(writer: anytype, elem: schema.ScalarKind) !void {
    if (elem == .f16) {
        try writer.writeAll("enable f16;\n\n");
    }
}
