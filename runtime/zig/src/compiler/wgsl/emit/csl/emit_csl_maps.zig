// emit_csl_maps.zig — WGSL → CSL name and type mappings.
//
// CSL is C-like with no vector/matrix primitives. WGSL vectors become arrays,
// matrices become 2-D arrays, and most math builtins map to the CSL math
// library or require inline expansion.

const std = @import("std");
const ir = @import("../../ir/ir.zig");

// ---------------------------------------------------------------------------
// Operators
// ---------------------------------------------------------------------------

pub fn unaryOpText(op: ir.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .not => "!",
        .bit_not => "~",
    };
}

pub fn binaryOpText(op: ir.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .rem => "%",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shift_left => "<<",
        .shift_right => ">>",
        .equal => "==",
        .not_equal => "!=",
        .less => "<",
        .less_equal => "<=",
        .greater => ">",
        .greater_equal => ">=",
        .logical_and => "and",
        .logical_or => "or",
    };
}

pub fn assignOpText(op: ir.AssignOp) []const u8 {
    return switch (op) {
        .assign => "=",
        .add => "+=",
        .sub => "-=",
        .mul => "*=",
        .div => "/=",
        .rem => "%=",
        .bit_and => "&=",
        .bit_or => "|=",
        .bit_xor => "^=",
    };
}

// ---------------------------------------------------------------------------
// Builtin function mapping
// ---------------------------------------------------------------------------

/// Returns the CSL math library equivalent for a WGSL builtin, or null if
/// the builtin needs special handling (inline expansion, DSD op, etc.).
pub fn cslMathBuiltin(name: []const u8) ?[]const u8 {
    // CSL math library functions (available via @import_module("<math>"))
    const direct_map = [_]struct { wgsl: []const u8, csl: []const u8 }{
        .{ .wgsl = "abs", .csl = "math.abs" },
        .{ .wgsl = "sqrt", .csl = "math.sqrt" },
        .{ .wgsl = "exp", .csl = "math.exp" },
        .{ .wgsl = "exp2", .csl = "math.exp2" },
        .{ .wgsl = "log", .csl = "math.log" },
        .{ .wgsl = "log2", .csl = "math.log2" },
        .{ .wgsl = "sin", .csl = "math.sin" },
        .{ .wgsl = "cos", .csl = "math.cos" },
        .{ .wgsl = "tanh", .csl = "math.tanh" },
        .{ .wgsl = "floor", .csl = "math.floor" },
        .{ .wgsl = "ceil", .csl = "math.ceil" },
        .{ .wgsl = "round", .csl = "math.round" },
        .{ .wgsl = "pow", .csl = "math.pow" },
    };
    inline for (direct_map) |entry| {
        if (std.mem.eql(u8, name, entry.wgsl)) return entry.csl;
    }
    return null;
}

/// Returns true if the WGSL builtin needs inline expansion in CSL because
/// there is no single-function equivalent.
pub fn needsInlineExpansion(name: []const u8) bool {
    const expanded = [_][]const u8{
        "clamp", // min(max(x, lo), hi)
        "min", // if (a < b) a else b  — or @fmins DSD op
        "max", // if (a > b) a else b  — or @fmaxs DSD op
        "fma", // a * b + c
        "mix", // x * (1 - t) + y * t
        "select", // if (cond) b else a
        "sign", // if (x > 0) 1 else if (x < 0) -1 else 0
        "step", // if (x >= edge) 1 else 0
        "smoothstep", // hermite interpolation
        "fract", // x - floor(x)
        "trunc", // sign(x) * floor(abs(x))
    };
    inline for (expanded) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Returns true for WGSL builtins that have no CSL equivalent and cause the
/// kernel to be classified as unsupported for CSL emission.
pub fn isUnsupportedBuiltin(name: []const u8) bool {
    const unsupported = [_][]const u8{
        // Texture operations — CSL has no texture hardware
        "textureSample",
        "textureSampleLevel",
        "textureSampleGrad",
        "textureSampleCompare",
        "textureLoad",
        "textureStore",
        "textureDimensions",
        "textureNumLayers",
        "textureNumLevels",
        "textureNumSamples",
        // Atomic operations — CSL has no shared-memory atomics
        "atomicLoad",
        "atomicStore",
        "atomicAdd",
        "atomicSub",
        "atomicMax",
        "atomicMin",
        "atomicAnd",
        "atomicOr",
        "atomicXor",
        "atomicExchange",
        "atomicCompareExchangeWeak",
        // Derivative operations — fragment-only
        "dpdx",
        "dpdy",
        "fwidth",
        // Subgroup operations — different model in CSL
        "subgroupAdd",
        "subgroupMul",
        "subgroupMin",
        "subgroupMax",
        "subgroupAnd",
        "subgroupOr",
        "subgroupXor",
        "subgroupBallot",
        "subgroupBroadcast",
        "subgroupBroadcastFirst",
        "subgroupShuffle",
    };
    inline for (unsupported) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}
