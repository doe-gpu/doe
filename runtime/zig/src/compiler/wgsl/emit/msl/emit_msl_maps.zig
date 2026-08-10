const std = @import("std");
const ir = @import("../../ir/ir.zig");
const operator_text = @import("../operator_text.zig");

pub const unary_op_text = operator_text.unaryOp;
pub const binary_op_text = operator_text.binaryOp;
pub const assign_op_text = operator_text.assignOp;

pub fn msl_function_name(name: []const u8, stage: ?ir.ShaderStage) []const u8 {
    if (stage) |active_stage| {
        if (std.mem.eql(u8, name, "main")) return switch (active_stage) {
            .compute => "main_kernel",
            .vertex => "main_vertex",
            .fragment => "main_fragment",
        };
    }
    return name;
}

pub fn msl_builtin_passthrough_name(name: []const u8) ?[]const u8 {
    // min, max, clamp are intentionally excluded: they require explicit
    // type casts on arguments to avoid MSL overload ambiguity and are
    // handled by emit_concrete_numeric_builtin instead.
    const passthrough = [_][]const u8{
        "abs",
        "acos",
        "asin",
        "atan",
        "atan2",
        "ceil",
        "cos",
        "cosh",
        "cross",
        "determinant",
        "distance",
        "dot",
        "exp",
        "exp2",
        "fma",
        "floor",
        "fract",
        "ldexp",
        "length",
        "log",
        "log2",
        "mix",
        "normalize",
        "pow",
        "reflect",
        "refract",
        "round",
        "saturate",
        "sign",
        "sin",
        "sinh",
        "smoothstep",
        "sqrt",
        "step",
        "tan",
        "tanh",
        "transpose",
        "trunc",
    };
    inline for (passthrough) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return candidate;
    }
    // Builtins where WGSL name differs from MSL name.
    const renamed = [_]struct { wgsl: []const u8, msl: []const u8 }{
        .{ .wgsl = "faceForward", .msl = "faceforward" },
        .{ .wgsl = "countOneBits", .msl = "popcount" },
        .{ .wgsl = "reverseBits", .msl = "reverse_bits" },
        .{ .wgsl = "countLeadingZeros", .msl = "clz" },
        .{ .wgsl = "countTrailingZeros", .msl = "ctz" },
    };
    inline for (renamed) |entry| {
        if (std.mem.eql(u8, name, entry.wgsl)) return entry.msl;
    }
    return null;
}

pub fn msl_builtin_name(builtin: ir.Builtin) []const u8 {
    return switch (builtin) {
        .position => "position",
        .frag_depth => "depth(any)",
        .front_facing => "front_facing",
        .global_invocation_id => "thread_position_in_grid",
        .local_invocation_id => "thread_position_in_threadgroup",
        .local_invocation_index => "thread_index_in_threadgroup",
        .workgroup_id => "threadgroup_position_in_grid",
        .num_workgroups => "threadgroups_per_grid",
        .sample_index => "sample_id",
        .sample_mask => "sample_mask",
        .vertex_index => "vertex_id",
        .instance_index => "instance_id",
        .subgroup_size => "threads_per_simdgroup",
        .subgroup_invocation_id => "thread_index_in_simdgroup",
        .clip_distances => "clip_distance",
        .primitive_index => "primitive_id",
        else => "unsupported_builtin",
    };
}

pub fn shouldForceLiteralCast(
    module: *const ir.Module,
    function: ir.Function,
    expr_id: ir.ExprId,
    target_ty: ir.TypeId,
) bool {
    if (function.exprs.items[expr_id].data != .int_lit) return false;
    return switch (module.types.get(target_ty)) {
        .scalar => |scalar| scalar == .u32,
        else => false,
    };
}

// MSL element type for a storage texture format.
// Float formats → "float", uint formats → "uint", sint formats → "int".
pub fn msl_storage_texture_elem(format: ir.TextureFormat) []const u8 {
    return switch (format) {
        .rgba8unorm, .rgba8snorm, .rgba16float, .r32float, .rg32float, .rgba32float => "float",

        .rgba8uint, .rgba16uint, .r32uint, .rg32uint, .rgba32uint => "uint",

        .rgba8sint, .rgba16sint, .r32sint, .rg32sint, .rgba32sint => "int",
    };
}
