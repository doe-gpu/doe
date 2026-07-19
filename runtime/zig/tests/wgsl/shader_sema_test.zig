// shader_sema_test.zig — Unit tests for subgroup mapping, type utilities, and TypeStore.
//
// Tests emit_msl_subgroups (WGSL subgroup -> MSL simd_* mapping table),
// sema_typeutils (bitcast compatibility, handle detection, type materialization),
// and ir.TypeStore (type interning/equality).

const std = @import("std");
const ir = @import("../../src/compiler/wgsl/ir/ir.zig");
const emit_msl_maps = @import("../../src/compiler/wgsl/emit/msl/emit_msl_maps.zig");
const emit_msl_subgroups = @import("../../src/compiler/wgsl/emit/msl/emit_msl_subgroups.zig");
const emit_spirv = @import("../../src/compiler/wgsl/emit/spirv/emit_spirv.zig");
const sema_typeutils = @import("../../src/compiler/wgsl/frontend/sema_typeutils.zig");
const sema_types = @import("../../src/compiler/wgsl/frontend/sema_types.zig");
const sema_helpers = @import("../../src/compiler/wgsl/frontend/sema_helpers.zig");

const testing = std.testing;
const allocator = testing.allocator;

// ============================================================
// emit_msl_subgroups tests
// ============================================================

const shared_io_builtins = [_]ir.Builtin{
    .position,
    .frag_depth,
    .front_facing,
    .global_invocation_id,
    .local_invocation_id,
    .local_invocation_index,
    .workgroup_id,
    .num_workgroups,
    .sample_index,
    .sample_mask,
    .vertex_index,
    .instance_index,
    .subgroup_size,
    .subgroup_invocation_id,
    .clip_distances,
    .primitive_index,
};

test "builtin parity: shared IO builtins have MSL and SPIR-V lowering" {
    for (shared_io_builtins) |builtin| {
        try testing.expect(!std.mem.eql(u8, emit_msl_maps.msl_builtin_name(builtin), "unsupported_builtin"));
        _ = try emit_spirv.builtin_to_spirv(builtin);
    }
}

test "subgroup mapping: all 18 WGSL subgroup builtins have MSL mappings" {
    const expected = [_]struct { wgsl: []const u8, msl: []const u8 }{
        .{ .wgsl = "subgroupBallot", .msl = "simd_ballot" },
        .{ .wgsl = "subgroupAll", .msl = "simd_all" },
        .{ .wgsl = "subgroupAny", .msl = "simd_any" },
        .{ .wgsl = "subgroupAdd", .msl = "simd_sum" },
        .{ .wgsl = "subgroupMin", .msl = "simd_min" },
        .{ .wgsl = "subgroupMax", .msl = "simd_max" },
        .{ .wgsl = "subgroupMul", .msl = "simd_product" },
        .{ .wgsl = "subgroupAnd", .msl = "simd_and" },
        .{ .wgsl = "subgroupOr", .msl = "simd_or" },
        .{ .wgsl = "subgroupXor", .msl = "simd_xor" },
        .{ .wgsl = "subgroupExclusiveAdd", .msl = "simd_prefix_exclusive_sum" },
        .{ .wgsl = "subgroupInclusiveAdd", .msl = "simd_prefix_inclusive_sum" },
        .{ .wgsl = "subgroupShuffle", .msl = "simd_shuffle" },
        .{ .wgsl = "subgroupShuffleDown", .msl = "simd_shuffle_down" },
        .{ .wgsl = "subgroupShuffleUp", .msl = "simd_shuffle_up" },
        .{ .wgsl = "subgroupShuffleXor", .msl = "simd_shuffle_xor" },
        .{ .wgsl = "subgroupBroadcast", .msl = "simd_broadcast" },
        .{ .wgsl = "subgroupBroadcastFirst", .msl = "simd_broadcast_first" },
    };

    var count: usize = 0;
    for (expected) |entry| {
        const result = emit_msl_subgroups.msl_name_for(entry.wgsl);
        try testing.expect(result != null);
        try testing.expectEqualStrings(entry.msl, result.?);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 18), count);
}

test "subgroup mapping: unknown name returns null" {
    try testing.expect(emit_msl_subgroups.msl_name_for("notASubgroupOp") == null);
    try testing.expect(emit_msl_subgroups.msl_name_for("") == null);
    try testing.expect(emit_msl_subgroups.msl_name_for("subgroup") == null);
    try testing.expect(emit_msl_subgroups.msl_name_for("subgroupSize") == null);
    try testing.expect(emit_msl_subgroups.msl_name_for("subgroupInvocationId") == null);
}

test "subgroup mapping: subgroupSize and subgroupInvocationId are parameter attributes, not function calls" {
    try testing.expect(emit_msl_subgroups.msl_name_for("subgroupSize") == null);
    try testing.expect(emit_msl_subgroups.msl_name_for("subgroupInvocationId") == null);
}

test "subgroup attribute: subgroup_size maps to threads_per_simdgroup" {
    const result = emit_msl_subgroups.msl_subgroup_attribute(.subgroup_size);
    try testing.expect(result != null);
    try testing.expectEqualStrings("threads_per_simdgroup", result.?);
}

test "subgroup attribute: subgroup_invocation_id maps to thread_index_in_simdgroup" {
    const result = emit_msl_subgroups.msl_subgroup_attribute(.subgroup_invocation_id);
    try testing.expect(result != null);
    try testing.expectEqualStrings("thread_index_in_simdgroup", result.?);
}

test "subgroup attribute: non-subgroup builtins return null" {
    try testing.expect(emit_msl_subgroups.msl_subgroup_attribute(.none) == null);
    try testing.expect(emit_msl_subgroups.msl_subgroup_attribute(.position) == null);
    try testing.expect(emit_msl_subgroups.msl_subgroup_attribute(.vertex_index) == null);
    try testing.expect(emit_msl_subgroups.msl_subgroup_attribute(.global_invocation_id) == null);
    try testing.expect(emit_msl_subgroups.msl_subgroup_attribute(.front_facing) == null);
    try testing.expect(emit_msl_subgroups.msl_subgroup_attribute(.frag_depth) == null);
    try testing.expect(emit_msl_subgroups.msl_subgroup_attribute(.sample_index) == null);
}

test "subgroup: SIMDGROUP_INCLUDE constant is correct" {
    try testing.expectEqualStrings("#include <metal_simdgroup>\n", emit_msl_subgroups.SIMDGROUP_INCLUDE);
}

test "subgroup: module_uses_subgroups returns false for empty module" {
    var module = ir.Module.init(allocator);
    defer module.deinit();

    try testing.expect(!emit_msl_subgroups.module_uses_subgroups(&module));
}

test "subgroup: module_uses_subgroups detects subgroup call in function expression" {
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const u32_type = try module.types.intern(.{ .scalar = .u32 });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn"),
        .return_type = u32_type,
        .stage = .compute,
    };
    try function.exprs.append(allocator, .{
        .ty = u32_type,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "subgroupAdd"),
            .kind = .builtin,
            .args = .{ .start = 0, .len = 0 },
        } },
    });
    const return_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{return_stmt});
    const block_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    function.root_stmt = block_stmt;

    try module.functions.append(allocator, function);

    try testing.expect(emit_msl_subgroups.module_uses_subgroups(&module));
}

test "subgroup: module_uses_subgroups detects subgroup_size param builtin" {
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const u32_type = try module.types.intern(.{ .scalar = .u32 });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn2"),
        .return_type = u32_type,
        .stage = .compute,
    };
    try function.params.append(allocator, .{
        .name = try ir.dup_string(allocator, "sg_size"),
        .ty = u32_type,
        .io = .{ .builtin = .subgroup_size },
    });
    const return_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{return_stmt});
    const block_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    function.root_stmt = block_stmt;

    try module.functions.append(allocator, function);

    try testing.expect(emit_msl_subgroups.module_uses_subgroups(&module));
}

test "subgroup: module_uses_subgroups returns false when only non-subgroup builtins used" {
    var module = ir.Module.init(allocator);
    defer module.deinit();

    const u32_type = try module.types.intern(.{ .scalar = .u32 });
    const vec3u_type = try module.types.intern(.{ .vector = .{ .elem = u32_type, .len = 3 } });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "compute_fn"),
        .return_type = try module.types.intern(.{ .scalar = .void }),
        .stage = .compute,
    };
    try function.params.append(allocator, .{
        .name = try ir.dup_string(allocator, "gid"),
        .ty = vec3u_type,
        .io = .{ .builtin = .global_invocation_id },
    });
    try function.exprs.append(allocator, .{
        .ty = u32_type,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "abs"),
            .kind = .builtin,
            .args = .{ .start = 0, .len = 0 },
        } },
    });
    const return_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{return_stmt});
    const block_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    function.root_stmt = block_stmt;

    try module.functions.append(allocator, function);

    try testing.expect(!emit_msl_subgroups.module_uses_subgroups(&module));
}

// ============================================================
// sema_typeutils tests
// ============================================================

fn make_semantic_module() !sema_types.SemanticModule {
    var module = sema_types.SemanticModule{
        .allocator = allocator,
        .tree = undefined,
        .types = ir.TypeStore.init(allocator),
    };
    try sema_helpers.init_builtin_types(&module);
    return module;
}

test "typeutils: bitcast_type_bits returns 32 for i32, u32, f32" {
    var module = try make_semantic_module();
    defer module.deinit();

    try testing.expectEqual(@as(?u32, 32), sema_typeutils.bitcast_type_bits(&module, module.i32_type));
    try testing.expectEqual(@as(?u32, 32), sema_typeutils.bitcast_type_bits(&module, module.u32_type));
    try testing.expectEqual(@as(?u32, 32), sema_typeutils.bitcast_type_bits(&module, module.f32_type));
}

test "typeutils: bitcast_type_bits returns 16 for f16" {
    var module = try make_semantic_module();
    defer module.deinit();

    try testing.expectEqual(@as(?u32, 16), sema_typeutils.bitcast_type_bits(&module, module.f16_type));
}

test "typeutils: bitcast_type_bits returns null for void and bool" {
    var module = try make_semantic_module();
    defer module.deinit();

    try testing.expect(sema_typeutils.bitcast_type_bits(&module, module.void_type) == null);
    try testing.expect(sema_typeutils.bitcast_type_bits(&module, module.bool_type) == null);
}

test "typeutils: bitcast_type_bits for vectors scales by element count" {
    var module = try make_semantic_module();
    defer module.deinit();

    const vec2f = try module.types.intern(.{ .vector = .{ .elem = module.f32_type, .len = 2 } });
    const vec4u = try module.types.intern(.{ .vector = .{ .elem = module.u32_type, .len = 4 } });
    const vec2h = try module.types.intern(.{ .vector = .{ .elem = module.f16_type, .len = 2 } });

    try testing.expectEqual(@as(?u32, 64), sema_typeutils.bitcast_type_bits(&module, vec2f));
    try testing.expectEqual(@as(?u32, 128), sema_typeutils.bitcast_type_bits(&module, vec4u));
    try testing.expectEqual(@as(?u32, 32), sema_typeutils.bitcast_type_bits(&module, vec2h));
}

test "typeutils: bitcast_type_bits returns null for non-scalar non-vector types" {
    var module = try make_semantic_module();
    defer module.deinit();

    const mat_ty = try module.types.intern(.{ .matrix = .{ .elem = module.f32_type, .columns = 4, .rows = 4 } });
    const arr_ty = try module.types.intern(.{ .array = .{ .elem = module.f32_type, .len = 4 } });

    try testing.expect(sema_typeutils.bitcast_type_bits(&module, mat_ty) == null);
    try testing.expect(sema_typeutils.bitcast_type_bits(&module, arr_ty) == null);
}

test "typeutils: bitcast_types_compatible with same-size scalar types" {
    var module = try make_semantic_module();
    defer module.deinit();

    try testing.expect(sema_typeutils.bitcast_types_compatible(&module, module.i32_type, module.u32_type));
    try testing.expect(sema_typeutils.bitcast_types_compatible(&module, module.u32_type, module.f32_type));
    try testing.expect(sema_typeutils.bitcast_types_compatible(&module, module.f32_type, module.i32_type));
}

test "typeutils: bitcast_types_compatible rejects different bit widths" {
    var module = try make_semantic_module();
    defer module.deinit();

    try testing.expect(!sema_typeutils.bitcast_types_compatible(&module, module.f16_type, module.f32_type));
    try testing.expect(!sema_typeutils.bitcast_types_compatible(&module, module.f32_type, module.f16_type));
}

test "typeutils: bitcast_types_compatible with vectors of matching total bits" {
    var module = try make_semantic_module();
    defer module.deinit();

    const vec2f = try module.types.intern(.{ .vector = .{ .elem = module.f32_type, .len = 2 } });
    const vec2u = try module.types.intern(.{ .vector = .{ .elem = module.u32_type, .len = 2 } });
    const vec4h = try module.types.intern(.{ .vector = .{ .elem = module.f16_type, .len = 4 } });

    try testing.expect(sema_typeutils.bitcast_types_compatible(&module, vec2f, vec2u));
    try testing.expect(sema_typeutils.bitcast_types_compatible(&module, vec2f, vec4h));
}

test "typeutils: bitcast_types_compatible rejects incompatible vector sizes" {
    var module = try make_semantic_module();
    defer module.deinit();

    const vec2f = try module.types.intern(.{ .vector = .{ .elem = module.f32_type, .len = 2 } });
    const vec4f = try module.types.intern(.{ .vector = .{ .elem = module.f32_type, .len = 4 } });

    try testing.expect(!sema_typeutils.bitcast_types_compatible(&module, vec2f, vec4f));
}

test "typeutils: bitcast_types_compatible rejects non-bitcastable types" {
    var module = try make_semantic_module();
    defer module.deinit();

    try testing.expect(!sema_typeutils.bitcast_types_compatible(&module, module.void_type, module.i32_type));
    try testing.expect(!sema_typeutils.bitcast_types_compatible(&module, module.bool_type, module.u32_type));
}

test "typeutils: is_handle_type identifies handle types correctly" {
    try testing.expect(sema_typeutils.is_handle_type(.{ .sampler = {} }));
    try testing.expect(sema_typeutils.is_handle_type(.{ .texture_2d = 0 }));
    try testing.expect(sema_typeutils.is_handle_type(.{ .texture_3d = 0 }));
    try testing.expect(sema_typeutils.is_handle_type(.{ .storage_texture_2d = .{ .format = .rgba8unorm, .access = .write } }));
}

test "typeutils: is_handle_type rejects non-handle types" {
    try testing.expect(!sema_typeutils.is_handle_type(.{ .scalar = .f32 }));
    try testing.expect(!sema_typeutils.is_handle_type(.{ .scalar = .void }));
    try testing.expect(!sema_typeutils.is_handle_type(.{ .vector = .{ .elem = 0, .len = 4 } }));
    try testing.expect(!sema_typeutils.is_handle_type(.{ .matrix = .{ .elem = 0, .columns = 4, .rows = 4 } }));
    try testing.expect(!sema_typeutils.is_handle_type(.{ .array = .{ .elem = 0, .len = 4 } }));
    try testing.expect(!sema_typeutils.is_handle_type(.{ .struct_ = 0 }));
    try testing.expect(!sema_typeutils.is_handle_type(.{ .atomic = 0 }));
}

test "typeutils: materialize_inferred_local_type concretizes abstract types" {
    var module = try make_semantic_module();
    defer module.deinit();

    try testing.expectEqual(module.i32_type, sema_typeutils.materialize_inferred_local_type(&module, module.abstract_int_type));
    try testing.expectEqual(module.f32_type, sema_typeutils.materialize_inferred_local_type(&module, module.abstract_float_type));
}

test "typeutils: materialize_inferred_local_type preserves concrete types" {
    var module = try make_semantic_module();
    defer module.deinit();

    try testing.expectEqual(module.i32_type, sema_typeutils.materialize_inferred_local_type(&module, module.i32_type));
    try testing.expectEqual(module.u32_type, sema_typeutils.materialize_inferred_local_type(&module, module.u32_type));
    try testing.expectEqual(module.f32_type, sema_typeutils.materialize_inferred_local_type(&module, module.f32_type));
    try testing.expectEqual(module.f16_type, sema_typeutils.materialize_inferred_local_type(&module, module.f16_type));
    try testing.expectEqual(module.bool_type, sema_typeutils.materialize_inferred_local_type(&module, module.bool_type));
}

test "typeutils: materialize_inferred_local_type passes through non-scalar types" {
    var module = try make_semantic_module();
    defer module.deinit();

    const vec_ty = try module.types.intern(.{ .vector = .{ .elem = module.f32_type, .len = 3 } });
    const arr_ty = try module.types.intern(.{ .array = .{ .elem = module.i32_type, .len = 10 } });

    try testing.expectEqual(vec_ty, sema_typeutils.materialize_inferred_local_type(&module, vec_ty));
    try testing.expectEqual(arr_ty, sema_typeutils.materialize_inferred_local_type(&module, arr_ty));
}

// ============================================================
// ir.TypeStore interning tests
// ============================================================

test "TypeStore: identical scalar types are interned to same id" {
    var store = ir.TypeStore.init(allocator);
    defer store.deinit();

    const a = try store.intern(.{ .scalar = .f32 });
    const b = try store.intern(.{ .scalar = .f32 });
    try testing.expectEqual(a, b);
}

test "TypeStore: different scalar types get different ids" {
    var store = ir.TypeStore.init(allocator);
    defer store.deinit();

    const f32_id = try store.intern(.{ .scalar = .f32 });
    const i32_id = try store.intern(.{ .scalar = .i32 });
    try testing.expect(f32_id != i32_id);
}

test "TypeStore: identical vector types are interned to same id" {
    var store = ir.TypeStore.init(allocator);
    defer store.deinit();

    const f32_id = try store.intern(.{ .scalar = .f32 });
    const a = try store.intern(.{ .vector = .{ .elem = f32_id, .len = 4 } });
    const b = try store.intern(.{ .vector = .{ .elem = f32_id, .len = 4 } });
    try testing.expectEqual(a, b);
}

test "TypeStore: vectors with different lengths get different ids" {
    var store = ir.TypeStore.init(allocator);
    defer store.deinit();

    const f32_id = try store.intern(.{ .scalar = .f32 });
    const vec2 = try store.intern(.{ .vector = .{ .elem = f32_id, .len = 2 } });
    const vec4 = try store.intern(.{ .vector = .{ .elem = f32_id, .len = 4 } });
    try testing.expect(vec2 != vec4);
}

test "TypeStore: get retrieves the correct type for a given id" {
    var store = ir.TypeStore.init(allocator);
    defer store.deinit();

    const f32_id = try store.intern(.{ .scalar = .f32 });
    const retrieved = store.get(f32_id);
    try testing.expectEqual(ir.ScalarType.f32, retrieved.scalar);
}
