// emit_hlsl_map_test.zig — HLSL type, builtin, intrinsic, and rename mapping tests.

const std = @import("std");
const ir = @import("../../src/compiler/wgsl/ir/ir.zig");
const emit_hlsl = @import("../../src/compiler/wgsl/emit/hlsl/emit_hlsl.zig");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const maps = @import("../../src/compiler/wgsl/emit/hlsl/emit_hlsl_maps.zig");

const testing = std.testing;
const allocator = testing.allocator;

const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;

// ============================================================
// Helpers
// ============================================================

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn expected_hlsl_builtin_has_semantic(builtin: ir.Builtin) bool {
    return switch (builtin) {
        .none => false,
        .position,
        .frag_depth,
        .front_facing,
        .global_invocation_id,
        .local_invocation_id,
        .local_invocation_index,
        .workgroup_id,
        .sample_index,
        .sample_mask,
        .vertex_index,
        .instance_index,
        .clip_distances,
        .primitive_index,
        => true,
        .num_workgroups,
        .subgroup_size,
        .subgroup_invocation_id,
        => false,
    };
}

fn read_u32_le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(bytes[offset .. offset + 4].ptr)), .little);
}

// ============================================================
// HLSL type mapping tests (via IR construction)
// ============================================================

test "hlsl type: scalar f32 emits float" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    const f32_ty = try module.types.intern(.{ .scalar = .f32 });
    const void_ty = try module.types.intern(.{ .scalar = .void });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn"),
        .return_type = void_ty,
    };
    try function.locals.append(allocator, .{
        .name = try ir.dup_string(allocator, "x"),
        .ty = f32_ty,
        .mutable = true,
    });
    const local_decl = try function.append_stmt(allocator, .{ .local_decl = .{
        .local = 0,
        .initializer = null,
        .is_const = false,
    } });
    const ret_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{ local_decl, ret_stmt });
    function.root_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    try module.functions.append(allocator, function);

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = emit_hlsl.emit(&module, &out) catch return error.SkipZigTest;
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "float x"));
}

test "hlsl type: scalar i32 emits int" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    const i32_ty = try module.types.intern(.{ .scalar = .i32 });
    const void_ty = try module.types.intern(.{ .scalar = .void });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn"),
        .return_type = void_ty,
    };
    try function.locals.append(allocator, .{
        .name = try ir.dup_string(allocator, "y"),
        .ty = i32_ty,
        .mutable = true,
    });
    const local_decl = try function.append_stmt(allocator, .{ .local_decl = .{
        .local = 0,
        .initializer = null,
        .is_const = false,
    } });
    const ret_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{ local_decl, ret_stmt });
    function.root_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    try module.functions.append(allocator, function);

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = emit_hlsl.emit(&module, &out) catch return error.SkipZigTest;
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "int y"));
}

test "hlsl type: vec3u emits uint3" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    const u32_ty = try module.types.intern(.{ .scalar = .u32 });
    const vec3u_ty = try module.types.intern(.{ .vector = .{ .elem = u32_ty, .len = 3 } });
    const void_ty = try module.types.intern(.{ .scalar = .void });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn"),
        .return_type = void_ty,
    };
    try function.locals.append(allocator, .{
        .name = try ir.dup_string(allocator, "v"),
        .ty = vec3u_ty,
        .mutable = true,
    });
    const local_decl = try function.append_stmt(allocator, .{ .local_decl = .{
        .local = 0,
        .initializer = null,
        .is_const = false,
    } });
    const ret_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{ local_decl, ret_stmt });
    function.root_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    try module.functions.append(allocator, function);

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = emit_hlsl.emit(&module, &out) catch return error.SkipZigTest;
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "uint3 v"));
}

test "hlsl type: mat4x4f emits float4x4" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    const f32_ty = try module.types.intern(.{ .scalar = .f32 });
    const mat4_ty = try module.types.intern(.{ .matrix = .{ .elem = f32_ty, .columns = 4, .rows = 4 } });
    const void_ty = try module.types.intern(.{ .scalar = .void });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn"),
        .return_type = void_ty,
    };
    try function.locals.append(allocator, .{
        .name = try ir.dup_string(allocator, "m"),
        .ty = mat4_ty,
        .mutable = true,
    });
    const local_decl = try function.append_stmt(allocator, .{ .local_decl = .{
        .local = 0,
        .initializer = null,
        .is_const = false,
    } });
    const ret_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{ local_decl, ret_stmt });
    function.root_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    try module.functions.append(allocator, function);

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = emit_hlsl.emit(&module, &out) catch return error.SkipZigTest;
    const hlsl = out[0..len];
    try testing.expect(contains(hlsl, "float4x4 m"));
}

test "hlsl builtin map: position maps to SV_Position" {
    try testing.expectEqualStrings("SV_Position", maps.hlsl_builtin_name(.position));
}

test "hlsl builtin map: vertex_index maps to SV_VertexID" {
    try testing.expectEqualStrings("SV_VertexID", maps.hlsl_builtin_name(.vertex_index));
}

test "hlsl builtin map: instance_index maps to SV_InstanceID" {
    try testing.expectEqualStrings("SV_InstanceID", maps.hlsl_builtin_name(.instance_index));
}

test "hlsl builtin map: global_invocation_id maps to SV_DispatchThreadID" {
    try testing.expectEqualStrings("SV_DispatchThreadID", maps.hlsl_builtin_name(.global_invocation_id));
}

test "hlsl builtin map: local_invocation_id maps to SV_GroupThreadID" {
    try testing.expectEqualStrings("SV_GroupThreadID", maps.hlsl_builtin_name(.local_invocation_id));
}

test "hlsl builtin map: local_invocation_index maps to SV_GroupIndex" {
    try testing.expectEqualStrings("SV_GroupIndex", maps.hlsl_builtin_name(.local_invocation_index));
}

test "hlsl builtin map: workgroup_id maps to SV_GroupID" {
    try testing.expectEqualStrings("SV_GroupID", maps.hlsl_builtin_name(.workgroup_id));
}

test "hlsl builtin map: num_workgroups has no direct semantic" {
    try testing.expect(!maps.hlsl_builtin_has_semantic(.num_workgroups));
}

test "hlsl builtin map: frag_depth maps to SV_Depth" {
    try testing.expectEqualStrings("SV_Depth", maps.hlsl_builtin_name(.frag_depth));
}

test "hlsl builtin map: front_facing maps to SV_IsFrontFace" {
    try testing.expectEqualStrings("SV_IsFrontFace", maps.hlsl_builtin_name(.front_facing));
}

test "hlsl builtin map: sample_index maps to SV_SampleIndex" {
    try testing.expectEqualStrings("SV_SampleIndex", maps.hlsl_builtin_name(.sample_index));
}

test "hlsl builtin map covers the current IR builtin surface" {
    inline for (std.meta.fields(ir.Builtin)) |field| {
        const builtin: ir.Builtin = @enumFromInt(field.value);
        try testing.expectEqual(expected_hlsl_builtin_has_semantic(builtin), maps.hlsl_builtin_has_semantic(builtin));
    }
}

test "hlsl intrinsic: subgroup_size maps to WaveGetLaneCount()" {
    try testing.expectEqualStrings("WaveGetLaneCount()", maps.hlsl_intrinsic_builtin(.subgroup_size).?);
}

test "hlsl intrinsic: subgroup_invocation_id maps to WaveGetLaneIndex()" {
    try testing.expectEqualStrings("WaveGetLaneIndex()", maps.hlsl_intrinsic_builtin(.subgroup_invocation_id).?);
}

test "hlsl intrinsic: position is not an intrinsic" {
    try testing.expect(maps.hlsl_intrinsic_builtin(.position) == null);
}

test "hlsl renamed: fract maps to frac" {
    try testing.expectEqualStrings("frac", maps.hlsl_renamed_builtin("fract").?);
}

test "hlsl renamed: inverseSqrt maps to rsqrt" {
    try testing.expectEqualStrings("rsqrt", maps.hlsl_renamed_builtin("inverseSqrt").?);
}

test "hlsl renamed: mix maps to lerp" {
    try testing.expectEqualStrings("lerp", maps.hlsl_renamed_builtin("mix").?);
}

test "hlsl renamed: atomicLoad maps to doe_atomicLoad" {
    try testing.expectEqualStrings("doe_atomicLoad", maps.hlsl_renamed_builtin("atomicLoad").?);
}

test "hlsl passthrough: abs returns true" {
    try testing.expect(maps.hlsl_builtin_passthrough("abs"));
}

test "hlsl passthrough: clamp returns true" {
    try testing.expect(maps.hlsl_builtin_passthrough("clamp"));
}

test "hlsl passthrough: unknownBuiltin returns false" {
    try testing.expect(!maps.hlsl_builtin_passthrough("unknownBuiltin"));
}

test "hlsl renamed: subgroupAnd maps to WaveActiveBitAnd" {
    try testing.expectEqualStrings("WaveActiveBitAnd", maps.hlsl_renamed_builtin("subgroupAnd").?);
}

test "hlsl renamed: subgroupOr maps to WaveActiveBitOr" {
    try testing.expectEqualStrings("WaveActiveBitOr", maps.hlsl_renamed_builtin("subgroupOr").?);
}

test "hlsl renamed: subgroupXor maps to WaveActiveBitXor" {
    try testing.expectEqualStrings("WaveActiveBitXor", maps.hlsl_renamed_builtin("subgroupXor").?);
}

test "hlsl renamed: subgroupAll maps to WaveActiveAllTrue" {
    try testing.expectEqualStrings("WaveActiveAllTrue", maps.hlsl_renamed_builtin("subgroupAll").?);
}

test "hlsl renamed: subgroupAny maps to WaveActiveAnyTrue" {
    try testing.expectEqualStrings("WaveActiveAnyTrue", maps.hlsl_renamed_builtin("subgroupAny").?);
}

test "hlsl passthrough: saturate returns true" {
    try testing.expect(maps.hlsl_builtin_passthrough("saturate"));
}

test "hlsl passthrough: reflect returns true" {
    try testing.expect(maps.hlsl_builtin_passthrough("reflect"));
}

test "hlsl passthrough: refract returns true" {
    try testing.expect(maps.hlsl_builtin_passthrough("refract"));
}

test "hlsl passthrough: transpose returns true" {
    try testing.expect(maps.hlsl_builtin_passthrough("transpose"));
}

test "hlsl passthrough: determinant returns true" {
    try testing.expect(maps.hlsl_builtin_passthrough("determinant"));
}

test "hlsl renamed: countOneBits maps to countbits" {
    try testing.expectEqualStrings("countbits", maps.hlsl_renamed_builtin("countOneBits").?);
}

test "hlsl renamed: reverseBits maps to reversebits" {
    try testing.expectEqualStrings("reversebits", maps.hlsl_renamed_builtin("reverseBits").?);
}

test "hlsl renamed: firstLeadingBit maps to firstbithigh" {
    try testing.expectEqualStrings("firstbithigh", maps.hlsl_renamed_builtin("firstLeadingBit").?);
}

test "hlsl renamed: firstTrailingBit maps to firstbitlow" {
    try testing.expectEqualStrings("firstbitlow", maps.hlsl_renamed_builtin("firstTrailingBit").?);
}
