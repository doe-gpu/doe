// emit_msl_subgroups.zig — WGSL subgroup built-in → MSL simd_group function mapping.
//
// All WGSL subgroup operations map to Metal's simd_* intrinsic family, which
// requires the metal_simdgroup header.  This module:
//   1. Detects whether any subgroup built-in is used in the IR.
//   2. Emits the header inclusion and built-in parameter declarations.
//   3. Provides the name-mapping table for emit_msl_ir.zig call emission.

const std = @import("std");
const ir = @import("../../ir/ir.zig");

// ============================================================
// Subgroup built-in name → MSL simd_* function mapping.
// ============================================================

const SubgroupMapping = struct {
    wgsl_name: []const u8,
    msl_name: []const u8,
    // Arity: number of arguments the WGSL builtin takes.
    arity: u8,
};

// Ordered table; lookup is linear (small table, called at compile-time only).
const SUBGROUP_MAP = [_]SubgroupMapping{
    .{ .wgsl_name = "subgroupBallot", .msl_name = "simd_ballot", .arity = 1 },
    .{ .wgsl_name = "subgroupAll", .msl_name = "simd_all", .arity = 1 },
    .{ .wgsl_name = "subgroupAny", .msl_name = "simd_any", .arity = 1 },
    .{ .wgsl_name = "subgroupAdd", .msl_name = "simd_sum", .arity = 1 },
    .{ .wgsl_name = "subgroupMin", .msl_name = "simd_min", .arity = 1 },
    .{ .wgsl_name = "subgroupMax", .msl_name = "simd_max", .arity = 1 },
    .{ .wgsl_name = "subgroupMul", .msl_name = "simd_product", .arity = 1 },
    .{ .wgsl_name = "subgroupAnd", .msl_name = "simd_and", .arity = 1 },
    .{ .wgsl_name = "subgroupOr", .msl_name = "simd_or", .arity = 1 },
    .{ .wgsl_name = "subgroupXor", .msl_name = "simd_xor", .arity = 1 },
    .{ .wgsl_name = "subgroupExclusiveAdd", .msl_name = "simd_prefix_exclusive_sum", .arity = 1 },
    .{ .wgsl_name = "subgroupInclusiveAdd", .msl_name = "simd_prefix_inclusive_sum", .arity = 1 },
    .{ .wgsl_name = "subgroupShuffle", .msl_name = "simd_shuffle", .arity = 2 },
    .{ .wgsl_name = "subgroupShuffleDown", .msl_name = "simd_shuffle_down", .arity = 2 },
    .{ .wgsl_name = "subgroupShuffleUp", .msl_name = "simd_shuffle_up", .arity = 2 },
    .{ .wgsl_name = "subgroupShuffleXor", .msl_name = "simd_shuffle_xor", .arity = 2 },
    .{ .wgsl_name = "subgroupBroadcast", .msl_name = "simd_broadcast", .arity = 2 },
    .{ .wgsl_name = "subgroupBroadcastFirst", .msl_name = "simd_broadcast_first", .arity = 1 },
    .{ .wgsl_name = "subgroupElect", .msl_name = "simd_is_first", .arity = 0 },
};

// Subgroup built-ins that map to [[thread_index_in_simdgroup]] parameter
// or [[threads_per_simdgroup]] attribute rather than a function call.
const SUBGROUP_SIZE_BUILTIN = "subgroupSize";
const SUBGROUP_INVOCATION_ID_BUILTIN = "subgroupInvocationId";

// ============================================================
// Public API
// ============================================================

// Return the MSL function name for a WGSL subgroup built-in call, or null
// if the name is not a subgroup built-in.
pub fn msl_name_for(wgsl_name: []const u8) ?[]const u8 {
    for (&SUBGROUP_MAP) |*entry| {
        if (std.mem.eql(u8, entry.wgsl_name, wgsl_name)) return entry.msl_name;
    }
    return null;
}

// Return true iff the module uses any subgroup built-in, which triggers
// inclusion of metal_simdgroup in the MSL preamble.
pub fn module_uses_subgroups(module: *const ir.Module) bool {
    for (module.functions.items) |function| {
        for (function.exprs.items) |expr_node| {
            switch (expr_node.data) {
                .call => |call| {
                    if (call.kind != .builtin) continue;
                    if (msl_name_for(call.name) != null) return true;
                    if (std.mem.eql(u8, call.name, SUBGROUP_SIZE_BUILTIN)) return true;
                    if (std.mem.eql(u8, call.name, SUBGROUP_INVOCATION_ID_BUILTIN)) return true;
                },
                else => {},
            }
        }
        for (function.params.items) |param| {
            if (param.io) |io| {
                switch (io.builtin) {
                    .subgroup_size, .subgroup_invocation_id => return true,
                    else => {},
                }
            }
        }
    }
    return false;
}

// Return the MSL built-in attribute string for subgroup-related builtins
// that map to [[thread_index_in_simdgroup]] or [[threads_per_simdgroup]].
// Returns null for non-subgroup builtins.
pub fn msl_subgroup_attribute(builtin_enum: ir.Builtin) ?[]const u8 {
    return switch (builtin_enum) {
        .subgroup_size => "threads_per_simdgroup",
        .subgroup_invocation_id => "thread_index_in_simdgroup",
        else => null,
    };
}

// MSL preamble include needed when subgroups are used.
pub const SIMDGROUP_INCLUDE = "#include <metal_simdgroup>\n";
