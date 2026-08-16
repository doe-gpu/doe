// ir_transform_robustness_test.zig - Tests for the robustness IR transform pass.
//
// Split from ir_transform_robustness.zig for line-limit compliance.

const support = @import("ir_transform_robustness_test_support.zig");
const std = support.std;
const testing = support.testing;
const ir = support.ir;
const apply = support.apply;
const make_test_module = support.make_test_module;
const u32_type = support.u32_type;
const f32_type = support.f32_type;
const add_struct_type = support.add_struct_type;
const resource_test = @import("ir_transform_robustness_resource_test.zig");
const guard_alias_test = @import("ir_transform_robustness_guard_alias_test.zig");

comptime {
    _ = resource_test;
    _ = guard_alias_test;
}

test "robustness: sized array index is clamped" {
    const allocator = testing.allocator;
    var module = try make_test_module(allocator);
    defer module.deinit();

    const f32_ty = f32_type(&module);
    const u32_ty = u32_type(&module);

    // array<f32, 10>
    const arr_ty = try module.types.intern(.{ .array = .{ .elem = f32_ty, .len = 10 } });
    const ref_arr_ty = try module.types.intern(.{ .ref = .{ .elem = arr_ty, .addr_space = .function, .access = .read_write } });

    // Add a global for the array
    try module.globals.append(allocator, .{
        .name = try ir.dup_string(allocator, "data"),
        .ty = ref_arr_ty,
        .class = .var_,
        .addr_space = .function,
    });

    // Build a function with: data[idx]
    var function = ir.Function{ .name = try ir.dup_string(allocator, "main"), .return_type = ir.INVALID_TYPE };
    errdefer function.deinit(allocator);

    // expr 0: global_ref(0) — the array
    const base_id = try function.append_expr(allocator, .{ .ty = ref_arr_ty, .category = .ref, .data = .{ .global_ref = 0 } });
    // expr 1: int_lit(15) — intentionally out-of-bounds index
    const idx_id = try function.append_expr(allocator, .{ .ty = u32_ty, .category = .value, .data = .{ .int_lit = 15 } });
    // expr 2: index { base, index }
    const index_id = try function.append_expr(allocator, .{ .ty = f32_ty, .category = .ref, .data = .{ .index = .{ .base = base_id, .index = idx_id } } });

    try module.functions.append(allocator, function);

    try apply(allocator, &module, .{});

    // The index expression should now reference a min() call, not the raw index.
    const transformed = module.functions.items[0].exprs.items[index_id];
    try testing.expect(transformed.data == .index);
    const new_index = transformed.data.index.index;
    // The new index should be a min() call appended after the original expressions.
    try testing.expect(new_index > index_id);

    const min_expr = module.functions.items[0].exprs.items[new_index];
    try testing.expect(min_expr.data == .call);
    try testing.expectEqualStrings("min", min_expr.data.call.name);
    try testing.expectEqual(@as(u32, 2), min_expr.data.call.args.len);
}

test "robustness: runtime storage contract preserves raw index" {
    const allocator = testing.allocator;
    var module = try make_test_module(allocator);
    defer module.deinit();

    const f32_ty = f32_type(&module);
    const u32_ty = u32_type(&module);
    const arr_ty = try module.types.intern(.{ .array = .{ .elem = f32_ty, .len = 10 } });
    const ref_arr_ty = try module.types.intern(.{ .ref = .{
        .elem = arr_ty,
        .addr_space = .storage,
        .access = .read_write,
    } });
    try module.globals.append(allocator, .{
        .name = try ir.dup_string(allocator, "data"),
        .ty = ref_arr_ty,
        .class = .var_,
        .addr_space = .storage,
    });

    var function = ir.Function{ .name = try ir.dup_string(allocator, "main"), .return_type = ir.INVALID_TYPE };
    errdefer function.deinit(allocator);
    const base_id = try function.append_expr(allocator, .{ .ty = ref_arr_ty, .category = .ref, .data = .{ .global_ref = 0 } });
    const idx_id = try function.append_expr(allocator, .{ .ty = u32_ty, .category = .value, .data = .{ .int_lit = 15 } });
    const index_id = try function.append_expr(allocator, .{ .ty = f32_ty, .category = .ref, .data = .{ .index = .{ .base = base_id, .index = idx_id } } });
    try module.functions.append(allocator, function);

    try apply(allocator, &module, .{ .rely_on_storage_buffer_robustness = true });

    const transformed = module.functions.items[0].exprs.items[index_id];
    try testing.expect(transformed.data == .index);
    try testing.expectEqual(idx_id, transformed.data.index.index);
}

test "robustness: vector index is clamped" {
    const allocator = testing.allocator;
    var module = try make_test_module(allocator);
    defer module.deinit();

    const f32_ty = f32_type(&module);
    const u32_ty = u32_type(&module);

    // vec4<f32>
    const vec_ty = try module.types.intern(.{ .vector = .{ .elem = f32_ty, .len = 4 } });

    var function = ir.Function{ .name = try ir.dup_string(allocator, "main"), .return_type = ir.INVALID_TYPE };
    errdefer function.deinit(allocator);

    try function.locals.append(allocator, .{ .name = try ir.dup_string(allocator, "v"), .ty = vec_ty, .mutable = false });

    // expr 0: local_ref(0) — the vector
    const base_id = try function.append_expr(allocator, .{ .ty = vec_ty, .category = .value, .data = .{ .local_ref = 0 } });
    // expr 1: int_lit(5) — out of bounds
    const idx_id = try function.append_expr(allocator, .{ .ty = u32_ty, .category = .value, .data = .{ .int_lit = 5 } });
    // expr 2: index { base, index }
    const index_id = try function.append_expr(allocator, .{ .ty = f32_ty, .category = .value, .data = .{ .index = .{ .base = base_id, .index = idx_id } } });

    try module.functions.append(allocator, function);
    try apply(allocator, &module, .{});

    const transformed = module.functions.items[0].exprs.items[index_id];
    const new_index = transformed.data.index.index;
    const min_expr = module.functions.items[0].exprs.items[new_index];
    try testing.expectEqualStrings("min", min_expr.data.call.name);

    // The max value should be vec.len - 1 = 3
    const max_arg_id = module.functions.items[0].expr_args.items[min_expr.data.call.args.start + 1];
    const max_expr = module.functions.items[0].exprs.items[max_arg_id];
    try testing.expectEqual(@as(u64, 3), max_expr.data.int_lit);
}

test "robustness: struct member and nested array indices are clamped" {
    const allocator = testing.allocator;
    var module = try make_test_module(allocator);
    defer module.deinit();

    const f32_ty = f32_type(&module);
    const u32_ty = u32_type(&module);

    // array<array<f32, 4>, 3>
    const inner_arr_ty = try module.types.intern(.{ .array = .{ .elem = f32_ty, .len = 4 } });
    const outer_arr_ty = try module.types.intern(.{ .array = .{ .elem = inner_arr_ty, .len = 3 } });
    const struct_ty = try add_struct_type(&module, allocator, "Wrapper", &.{
        .{ .name = "data", .ty = outer_arr_ty },
    });

    var function = ir.Function{ .name = try ir.dup_string(allocator, "main"), .return_type = ir.INVALID_TYPE };
    errdefer function.deinit(allocator);

    try function.locals.append(allocator, .{
        .name = try ir.dup_string(allocator, "wrapper"),
        .ty = struct_ty,
        .mutable = false,
    });

    const base_id = try function.append_expr(allocator, .{
        .ty = struct_ty,
        .category = .value,
        .data = .{ .local_ref = 0 },
    });
    const member_id = try function.append_expr(allocator, .{
        .ty = outer_arr_ty,
        .category = .value,
        .data = .{
            .member = .{
                .base = base_id,
                .field_name = try ir.dup_string(allocator, "data"),
                .field_index = 0,
            },
        },
    });
    const outer_idx_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 9 },
    });
    const outer_access_id = try function.append_expr(allocator, .{
        .ty = inner_arr_ty,
        .category = .value,
        .data = .{ .index = .{ .base = member_id, .index = outer_idx_id } },
    });
    const inner_idx_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 8 },
    });
    const inner_access_id = try function.append_expr(allocator, .{
        .ty = f32_ty,
        .category = .value,
        .data = .{ .index = .{ .base = outer_access_id, .index = inner_idx_id } },
    });

    try module.functions.append(allocator, function);
    try apply(allocator, &module, .{});

    const outer_transformed = module.functions.items[0].exprs.items[outer_access_id];
    try testing.expect(outer_transformed.data == .index);
    const outer_min_id = outer_transformed.data.index.index;
    const outer_min_expr = module.functions.items[0].exprs.items[outer_min_id];
    try testing.expectEqualStrings("min", outer_min_expr.data.call.name);
    const outer_max_id = module.functions.items[0].expr_args.items[outer_min_expr.data.call.args.start + 1];
    const outer_max_expr = module.functions.items[0].exprs.items[outer_max_id];
    try testing.expectEqual(@as(u64, 2), outer_max_expr.data.int_lit);

    const inner_transformed = module.functions.items[0].exprs.items[inner_access_id];
    try testing.expect(inner_transformed.data == .index);
    const inner_min_id = inner_transformed.data.index.index;
    const inner_min_expr = module.functions.items[0].exprs.items[inner_min_id];
    try testing.expectEqualStrings("min", inner_min_expr.data.call.name);
    const inner_max_id = module.functions.items[0].expr_args.items[inner_min_expr.data.call.args.start + 1];
    const inner_max_expr = module.functions.items[0].exprs.items[inner_max_id];
    try testing.expectEqual(@as(u64, 3), inner_max_expr.data.int_lit);
}

test "robustness: nested refs to arrays are unwrapped for clamping" {
    const allocator = testing.allocator;
    var module = try make_test_module(allocator);
    defer module.deinit();

    const f32_ty = f32_type(&module);
    const u32_ty = u32_type(&module);

    const arr_ty = try module.types.intern(.{ .array = .{ .elem = f32_ty, .len = 5 } });
    const ref_ty = try module.types.intern(.{ .ref = .{
        .elem = arr_ty,
        .addr_space = .function,
        .access = .read_write,
    } });
    const nested_ref_ty = try module.types.intern(.{ .ref = .{
        .elem = ref_ty,
        .addr_space = .function,
        .access = .read_write,
    } });

    var function = ir.Function{ .name = try ir.dup_string(allocator, "main"), .return_type = ir.INVALID_TYPE };
    errdefer function.deinit(allocator);

    try function.locals.append(allocator, .{
        .name = try ir.dup_string(allocator, "data"),
        .ty = nested_ref_ty,
        .mutable = false,
    });

    const base_id = try function.append_expr(allocator, .{
        .ty = nested_ref_ty,
        .category = .value,
        .data = .{ .local_ref = 0 },
    });
    const idx_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 11 },
    });
    const index_id = try function.append_expr(allocator, .{
        .ty = f32_ty,
        .category = .value,
        .data = .{ .index = .{ .base = base_id, .index = idx_id } },
    });

    try module.functions.append(allocator, function);
    try apply(allocator, &module, .{});

    const transformed = module.functions.items[0].exprs.items[index_id];
    try testing.expect(transformed.data == .index);
    const new_index = transformed.data.index.index;
    const min_expr = module.functions.items[0].exprs.items[new_index];
    try testing.expectEqualStrings("min", min_expr.data.call.name);
    const max_arg_id = module.functions.items[0].expr_args.items[min_expr.data.call.args.start + 1];
    const max_expr = module.functions.items[0].exprs.items[max_arg_id];
    try testing.expectEqual(@as(u64, 4), max_expr.data.int_lit);
}

test "robustness: runtime-sized array uses arrayLength" {
    const allocator = testing.allocator;
    var module = try make_test_module(allocator);
    defer module.deinit();

    const f32_ty = f32_type(&module);
    const u32_ty = u32_type(&module);

    const arr_ty = try module.types.intern(.{ .array = .{ .elem = f32_ty, .len = null } });
    const ref_arr_ty = try module.types.intern(.{ .ref = .{ .elem = arr_ty, .addr_space = .storage, .access = .read_write } });

    try module.globals.append(allocator, .{
        .name = try ir.dup_string(allocator, "buf"),
        .ty = ref_arr_ty,
        .class = .var_,
        .addr_space = .storage,
        .access = .read_write,
        .binding = .{ .group = 0, .binding = 0 },
    });

    var function = ir.Function{ .name = try ir.dup_string(allocator, "main"), .return_type = ir.INVALID_TYPE };
    errdefer function.deinit(allocator);

    const base_id = try function.append_expr(allocator, .{ .ty = ref_arr_ty, .category = .ref, .data = .{ .global_ref = 0 } });
    const idx_id = try function.append_expr(allocator, .{ .ty = u32_ty, .category = .value, .data = .{ .int_lit = 100 } });
    const index_id = try function.append_expr(allocator, .{ .ty = f32_ty, .category = .ref, .data = .{ .index = .{ .base = base_id, .index = idx_id } } });

    try module.functions.append(allocator, function);
    try apply(allocator, &module, .{});

    const transformed = module.functions.items[0].exprs.items[index_id];
    const new_index = transformed.data.index.index;
    const min_expr = module.functions.items[0].exprs.items[new_index];
    try testing.expectEqualStrings("min", min_expr.data.call.name);

    const first_arg = module.functions.items[0].expr_args.items[min_expr.data.call.args.start];
    try testing.expectEqual(idx_id, first_arg);

    const second_arg_id = module.functions.items[0].expr_args.items[min_expr.data.call.args.start + 1];
    const sub_expr = module.functions.items[0].exprs.items[second_arg_id];
    try testing.expect(sub_expr.data == .binary);
    try testing.expectEqual(ir.BinaryOp.sub, sub_expr.data.binary.op);

    const al_expr = module.functions.items[0].exprs.items[sub_expr.data.binary.lhs];
    try testing.expect(al_expr.data == .call);
    try testing.expectEqualStrings("arrayLength", al_expr.data.call.name);
}

test "robustness: runtime-sized array member uses arrayLength" {
    const allocator = testing.allocator;
    var module = try make_test_module(allocator);
    defer module.deinit();

    const f32_ty = f32_type(&module);
    const u32_ty = u32_type(&module);

    const arr_ty = try module.types.intern(.{ .array = .{ .elem = f32_ty, .len = null } });
    const struct_ty = try add_struct_type(&module, allocator, "Wrapper", &.{
        .{ .name = "data", .ty = arr_ty },
    });
    const ref_struct_ty = try module.types.intern(.{ .ref = .{
        .elem = struct_ty,
        .addr_space = .storage,
        .access = .read_write,
    } });

    try module.globals.append(allocator, .{
        .name = try ir.dup_string(allocator, "buf"),
        .ty = ref_struct_ty,
        .class = .var_,
        .addr_space = .storage,
        .access = .read_write,
        .binding = .{ .group = 0, .binding = 0 },
    });

    var function = ir.Function{ .name = try ir.dup_string(allocator, "main"), .return_type = ir.INVALID_TYPE };

    const root_id = try function.append_expr(allocator, .{
        .ty = ref_struct_ty,
        .category = .ref,
        .data = .{ .global_ref = 0 },
    });
    const member_id = try function.append_expr(allocator, .{
        .ty = arr_ty,
        .category = .ref,
        .data = .{ .member = .{
            .base = root_id,
            .field_name = try ir.dup_string(allocator, "data"),
            .field_index = 0,
        } },
    });
    const idx_id = try function.append_expr(allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 9 },
    });
    const index_id = try function.append_expr(allocator, .{
        .ty = f32_ty,
        .category = .ref,
        .data = .{ .index = .{
            .base = member_id,
            .index = idx_id,
        } },
    });

    try module.functions.append(allocator, function);
    try apply(allocator, &module, .{});

    const transformed = module.functions.items[0].exprs.items[index_id];
    const min_id = transformed.data.index.index;
    const min_expr = module.functions.items[0].exprs.items[min_id];
    try testing.expectEqualStrings("min", min_expr.data.call.name);
    const second_arg_id = module.functions.items[0].expr_args.items[min_expr.data.call.args.start + 1];
    const second_arg_expr = module.functions.items[0].exprs.items[second_arg_id];
    try testing.expect(second_arg_expr.data == .binary);
    try testing.expectEqual(ir.BinaryOp.sub, second_arg_expr.data.binary.op);
    const array_length_expr = module.functions.items[0].exprs.items[second_arg_expr.data.binary.lhs];
    try testing.expect(array_length_expr.data == .call);
    try testing.expectEqualStrings("arrayLength", array_length_expr.data.call.name);
    const array_length_arg = module.functions.items[0].expr_args.items[array_length_expr.data.call.args.start];
    try testing.expectEqual(member_id, array_length_arg);
}

test "robustness: non-index expressions are unchanged" {
    const allocator = testing.allocator;
    var module = try make_test_module(allocator);
    defer module.deinit();

    const u32_ty = u32_type(&module);

    var function = ir.Function{ .name = try ir.dup_string(allocator, "main"), .return_type = ir.INVALID_TYPE };
    errdefer function.deinit(allocator);

    _ = try function.append_expr(allocator, .{ .ty = u32_ty, .category = .value, .data = .{ .int_lit = 42 } });
    _ = try function.append_expr(allocator, .{ .ty = u32_ty, .category = .value, .data = .{ .binary = .{ .op = .add, .lhs = 0, .rhs = 0 } } });

    try module.functions.append(allocator, function);

    const original_count = module.functions.items[0].exprs.items.len;
    try apply(allocator, &module, .{});

    try testing.expectEqual(original_count, module.functions.items[0].exprs.items.len);
}

test "robustness: matrix column index is clamped" {
    const allocator = testing.allocator;
    var module = try make_test_module(allocator);
    defer module.deinit();

    const f32_ty = f32_type(&module);
    const u32_ty = u32_type(&module);

    const vec3_ty = try module.types.intern(.{ .vector = .{ .elem = f32_ty, .len = 3 } });
    const mat_ty = try module.types.intern(.{ .matrix = .{ .elem = f32_ty, .columns = 3, .rows = 3 } });

    var function = ir.Function{ .name = try ir.dup_string(allocator, "main"), .return_type = ir.INVALID_TYPE };
    errdefer function.deinit(allocator);

    try function.locals.append(allocator, .{ .name = try ir.dup_string(allocator, "m"), .ty = mat_ty, .mutable = false });

    const base_id = try function.append_expr(allocator, .{ .ty = mat_ty, .category = .value, .data = .{ .local_ref = 0 } });
    const idx_id = try function.append_expr(allocator, .{ .ty = u32_ty, .category = .value, .data = .{ .int_lit = 7 } });
    const index_id = try function.append_expr(allocator, .{ .ty = vec3_ty, .category = .value, .data = .{ .index = .{ .base = base_id, .index = idx_id } } });

    try module.functions.append(allocator, function);
    try apply(allocator, &module, .{});

    const transformed = module.functions.items[0].exprs.items[index_id];
    const new_index = transformed.data.index.index;
    const min_expr = module.functions.items[0].exprs.items[new_index];
    try testing.expectEqualStrings("min", min_expr.data.call.name);

    const max_arg_id = module.functions.items[0].expr_args.items[min_expr.data.call.args.start + 1];
    const max_expr = module.functions.items[0].exprs.items[max_arg_id];
    try testing.expectEqual(@as(u64, 2), max_expr.data.int_lit);
}
