// wgsl_parser_ir_test.zig — Tests for WGSL parser expressions, IR, robustness
// transforms, and semantic analysis helpers. All pure logic — no GPU needed.

const std = @import("std");
const testing = std.testing;
const ast_mod = @import("../../src/compiler/wgsl/frontend/ast.zig");
const token_mod = @import("../../src/compiler/wgsl/frontend/token.zig");
const ir = @import("../../src/compiler/wgsl/ir/ir.zig");
const parser_mod = @import("../../src/compiler/wgsl/frontend/parser.zig");
const robustness = @import("../../src/compiler/wgsl/ir/ir_transform_robustness.zig");
const sema = @import("../../src/compiler/wgsl/frontend/sema.zig");
const sema_helpers = @import("../../src/compiler/wgsl/frontend/sema_helpers.zig");
const sema_typeutils = @import("../../src/compiler/wgsl/frontend/sema_typeutils.zig");
const Ast = ast_mod.Ast;
const NodeTag = ast_mod.NodeTag;
const Tag = token_mod.Tag;
const NULL_NODE = ast_mod.NULL_NODE;

fn parseSource(source: []const u8) !Ast {
    return parser_mod.parseSource(testing.allocator, source);
}

fn hasNodeTag(tree: *const Ast, tag: NodeTag) bool {
    for (tree.nodes.items) |n| {
        if (n.tag == tag) return true;
    }
    return false;
}

fn buildIndexedArrayModule(array_len: ?u32) !struct { module: ir.Module } {
    var module = ir.Module.init(testing.allocator);
    errdefer module.deinit();
    const u32_ty = try module.types.intern(.{ .scalar = .u32 });
    const arr_ty = try module.types.intern(.{ .array = .{ .elem = u32_ty, .len = array_len } });
    const ref_ty = try module.types.intern(.{ .ref = .{
        .elem = arr_ty,
        .addr_space = .storage,
        .access = .read_write,
    } });
    try module.globals.append(module.allocator, .{
        .name = try ir.dup_string(module.allocator, "buf"),
        .ty = ref_ty,
        .class = .var_,
        .addr_space = .storage,
        .access = .read_write,
        .binding = .{ .group = 0, .binding = 0 },
    });
    var func = ir.Function{
        .name = try ir.dup_string(module.allocator, "main"),
        .return_type = try module.types.intern(.{ .scalar = .void }),
        .stage = .compute,
    };
    _ = try func.append_expr(module.allocator, .{
        .ty = ref_ty,
        .category = .ref,
        .data = .{ .global_ref = 0 },
    });
    _ = try func.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .value,
        .data = .{ .int_lit = 5 },
    });
    _ = try func.append_expr(module.allocator, .{
        .ty = u32_ty,
        .category = .ref,
        .data = .{ .index = .{ .base = 0, .index = 1 } },
    });
    try module.functions.append(module.allocator, func);
    return .{ .module = module };
}

// ---- Parser: simple expressions ----

test "parser: int literal" {
    var tree = try parseSource("const x: u32 = 42;");
    defer tree.deinit();
    try testing.expect(hasNodeTag(&tree, .int_literal));
}

test "parser: float literal" {
    var tree = try parseSource("const x: f32 = 3.14;");
    defer tree.deinit();
    try testing.expect(hasNodeTag(&tree, .float_literal));
}

test "parser: bool literal" {
    var tree = try parseSource("const x: bool = true;");
    defer tree.deinit();
    try testing.expect(hasNodeTag(&tree, .bool_literal));
}

test "parser: binary op" {
    var tree = try parseSource("const x: u32 = 1 + 2;");
    defer tree.deinit();
    try testing.expect(hasNodeTag(&tree, .binary_expr));
}

test "parser: function call" {
    var tree = try parseSource(
        \\fn h(a: f32) -> f32 { return a; }
        \\fn m() { let x = h(1.0); }
    );
    defer tree.deinit();
    try testing.expect(hasNodeTag(&tree, .call_expr));
}

// ---- Parser: operator precedence ----

test "parser: mul binds tighter than add" {
    var tree = try parseSource("const x: u32 = 1 + 2 * 3;");
    defer tree.deinit();
    // Find the const_decl initializer.
    for (tree.nodes.items) |node| {
        if (node.tag == .const_decl and node.data.rhs != NULL_NODE) {
            const init = tree.nodes.items[node.data.rhs];
            try testing.expectEqual(NodeTag.binary_expr, init.tag);
            try testing.expectEqualStrings("+", tree.tokenSlice(init.main_token));
            const rhs = tree.nodes.items[init.data.rhs];
            try testing.expectEqual(NodeTag.binary_expr, rhs.tag);
            try testing.expectEqualStrings("*", tree.tokenSlice(rhs.main_token));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

test "parser: shift binds tighter than comparison" {
    var tree = try parseSource("const x: bool = 1 < 2 << 3;");
    defer tree.deinit();
    var found_lt = false;
    var found_shift = false;
    for (tree.nodes.items) |node| {
        if (node.tag == .binary_expr) {
            const op = tree.tokenSlice(node.main_token);
            if (std.mem.eql(u8, op, "<")) found_lt = true;
            if (std.mem.eql(u8, op, "<<")) found_shift = true;
        }
    }
    try testing.expect(found_lt and found_shift);
}

// ---- Parser: parenthesized expressions ----

test "parser: parens override precedence" {
    var tree = try parseSource("const x: u32 = (1 + 2) * 3;");
    defer tree.deinit();
    for (tree.nodes.items) |node| {
        if (node.tag == .const_decl and node.data.rhs != NULL_NODE) {
            const init = tree.nodes.items[node.data.rhs];
            try testing.expectEqual(NodeTag.binary_expr, init.tag);
            try testing.expectEqualStrings("*", tree.tokenSlice(init.main_token));
            const lhs = tree.nodes.items[init.data.lhs];
            try testing.expectEqual(NodeTag.binary_expr, lhs.tag);
            try testing.expectEqualStrings("+", tree.tokenSlice(lhs.main_token));
            return;
        }
    }
    return error.TestUnexpectedResult;
}

// ---- Parser: malformed input ----

test "parser: unclosed paren returns error" {
    try testing.expectError(error.UnexpectedToken, parseSource("const x: u32 = (1 + 2;"));
}

test "parser: empty source parses to empty root" {
    var tree = try parseSource("");
    defer tree.deinit();
    try testing.expectEqual(@as(u32, 0), tree.nodes.items[0].data.rhs);
}

test "parser: bare operator rejected" {
    try testing.expectError(error.UnexpectedToken, parseSource("+ 1"));
}

// ---- Parser: deeply nested expressions ----

test "parser: 64-level nested parens" {
    const depth = 64;
    const prefix = "const x: u32 = ";
    const suffix = ";";
    var buf: [prefix.len + depth + 1 + depth + suffix.len]u8 = undefined;
    var pos: usize = 0;
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;
    for (0..depth) |_| {
        buf[pos] = '(';
        pos += 1;
    }
    buf[pos] = '1';
    pos += 1;
    for (0..depth) |_| {
        buf[pos] = ')';
        pos += 1;
    }
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;
    var tree = try parseSource(buf[0..pos]);
    defer tree.deinit();
    try testing.expect(hasNodeTag(&tree, .int_literal));
}

// ---- Parser: type expressions and postfix ----

test "parser: vec4f shorthand" {
    var tree = try parseSource("const x: vec4f = vec4f(1.0, 2.0, 3.0, 4.0);");
    defer tree.deinit();
    try testing.expect(hasNodeTag(&tree, .type_vec_shorthand));
}

test "parser: member_expr" {
    var tree = try parseSource(
        \\struct S { x: u32 }
        \\fn f(s: S) -> u32 { return s.x; }
    );
    defer tree.deinit();
    try testing.expect(hasNodeTag(&tree, .member_expr));
}

test "parser: index_expr" {
    var tree = try parseSource("fn f(a: array<u32, 4>) -> u32 { return a[0]; }");
    defer tree.deinit();
    try testing.expect(hasNodeTag(&tree, .index_expr));
}

// ---- IR: TypeStore ----

test "ir: intern deduplicates identical types" {
    var store = ir.TypeStore.init(testing.allocator);
    defer store.deinit();
    const a = try store.intern(.{ .scalar = .f32 });
    const b = try store.intern(.{ .scalar = .f32 });
    try testing.expectEqual(a, b);
}

test "ir: intern assigns distinct ids to different types" {
    var store = ir.TypeStore.init(testing.allocator);
    defer store.deinit();
    const f = try store.intern(.{ .scalar = .f32 });
    const u = try store.intern(.{ .scalar = .u32 });
    try testing.expect(f != u);
}

test "ir: round-trip vector type" {
    var store = ir.TypeStore.init(testing.allocator);
    defer store.deinit();
    const f32_id = try store.intern(.{ .scalar = .f32 });
    const v = try store.intern(.{ .vector = .{ .elem = f32_id, .len = 4 } });
    const got = store.get(v);
    try testing.expectEqual(@as(u8, 4), got.vector.len);
    try testing.expectEqual(f32_id, got.vector.elem);
}

// ---- IR: enum stability ----

test "ir: ScalarType members are distinct" {
    const all = [_]ir.ScalarType{ .void, .bool, .i32, .u32, .f32, .f16, .abstract_int, .abstract_float };
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| try testing.expect(a != b);
    }
}

test "ir: BinaryOp members are distinct" {
    const all = [_]ir.BinaryOp{ .add, .sub, .mul, .div, .rem, .equal, .not_equal, .less, .greater, .logical_and, .logical_or };
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| try testing.expect(a != b);
    }
}

test "ir: AddressSpace members are distinct" {
    const all = [_]ir.AddressSpace{ .function, .private, .workgroup, .uniform, .storage, .handle };
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| try testing.expect(a != b);
    }
}

// ---- IR: Module/Function builder ----

test "ir: Module init/deinit is clean" {
    var m = ir.Module.init(testing.allocator);
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.functions.items.len);
}

test "ir: sequential expr and stmt ids" {
    var f = ir.Function{
        .name = try ir.dup_string(testing.allocator, "t"),
        .return_type = ir.INVALID_TYPE,
    };
    defer f.deinit(testing.allocator);
    const e0 = try f.append_expr(testing.allocator, .{ .ty = ir.INVALID_TYPE, .category = .value, .data = .{ .int_lit = 1 } });
    const e1 = try f.append_expr(testing.allocator, .{ .ty = ir.INVALID_TYPE, .category = .value, .data = .{ .int_lit = 2 } });
    try testing.expectEqual(@as(ir.ExprId, 0), e0);
    try testing.expectEqual(@as(ir.ExprId, 1), e1);
    const s0 = try f.append_stmt(testing.allocator, .{ .return_ = null });
    try testing.expectEqual(@as(ir.StmtId, 0), s0);
}

test "ir: append_expr_args range" {
    var f = ir.Function{
        .name = try ir.dup_string(testing.allocator, "t"),
        .return_type = ir.INVALID_TYPE,
    };
    defer f.deinit(testing.allocator);
    const r = try f.append_expr_args(testing.allocator, &.{ 10, 20, 30 });
    try testing.expectEqual(@as(u32, 0), r.start);
    try testing.expectEqual(@as(u32, 3), r.len);
}

// ---- IR: expression tree traversal ----

test "ir: traverse binary expression tree" {
    var f = ir.Function{
        .name = try ir.dup_string(testing.allocator, "t"),
        .return_type = ir.INVALID_TYPE,
    };
    defer f.deinit(testing.allocator);
    const a = try f.append_expr(testing.allocator, .{ .ty = ir.INVALID_TYPE, .category = .value, .data = .{ .int_lit = 1 } });
    const b = try f.append_expr(testing.allocator, .{ .ty = ir.INVALID_TYPE, .category = .value, .data = .{ .int_lit = 2 } });
    const add = try f.append_expr(testing.allocator, .{
        .ty = ir.INVALID_TYPE,
        .category = .value,
        .data = .{ .binary = .{ .op = .add, .lhs = a, .rhs = b } },
    });
    const root = f.exprs.items[add];
    try testing.expectEqual(ir.BinaryOp.add, root.data.binary.op);
    try testing.expectEqual(@as(u64, 1), f.exprs.items[root.data.binary.lhs].data.int_lit);
    try testing.expectEqual(@as(u64, 2), f.exprs.items[root.data.binary.rhs].data.int_lit);
}

// ---- Robustness: sized array clamping ----

test "robustness: sized array index gets clamped" {
    var r = try buildIndexedArrayModule(16);
    defer r.module.deinit();
    const before = r.module.functions.items[0].exprs.items.len;
    try robustness.apply(testing.allocator, &r.module, .{});
    const func = &r.module.functions.items[0];
    try testing.expect(func.exprs.items.len > before);
    const idx = func.exprs.items[2].data.index;
    try testing.expect(idx.index != 1);
    try testing.expectEqualStrings("min", func.exprs.items[idx.index].data.call.name);
}

test "robustness: runtime-sized array gets arrayLength clamp" {
    var r = try buildIndexedArrayModule(null);
    defer r.module.deinit();
    try robustness.apply(testing.allocator, &r.module, .{});
    const func = &r.module.functions.items[0];
    try testing.expect(func.exprs.items[2].data.index.index != 1);
    var found = false;
    for (func.exprs.items) |e| {
        if (e.data == .call and std.mem.eql(u8, e.data.call.name, "arrayLength")) found = true;
    }
    try testing.expect(found);
}

// ---- Robustness: no-op cases ----

test "robustness: no clamping on plain expressions" {
    var m = ir.Module.init(testing.allocator);
    defer m.deinit();
    const f32_ty = try m.types.intern(.{ .scalar = .f32 });
    var func = ir.Function{
        .name = try ir.dup_string(m.allocator, "n"),
        .return_type = try m.types.intern(.{ .scalar = .void }),
    };
    _ = try func.append_expr(m.allocator, .{ .ty = f32_ty, .category = .value, .data = .{ .float_lit = 3.14 } });
    try m.functions.append(m.allocator, func);
    const before = m.functions.items[0].exprs.items.len;
    try robustness.apply(testing.allocator, &m, .{});
    try testing.expectEqual(before, m.functions.items[0].exprs.items.len);
}

test "robustness: vector index clamped to vec length" {
    var m = ir.Module.init(testing.allocator);
    defer m.deinit();
    const f32_ty = try m.types.intern(.{ .scalar = .f32 });
    const u32_ty = try m.types.intern(.{ .scalar = .u32 });
    const vec4f = try m.types.intern(.{ .vector = .{ .elem = f32_ty, .len = 4 } });
    var func = ir.Function{
        .name = try ir.dup_string(m.allocator, "v"),
        .return_type = try m.types.intern(.{ .scalar = .void }),
    };
    _ = try func.append_expr(m.allocator, .{ .ty = vec4f, .category = .value, .data = .{ .int_lit = 0 } });
    _ = try func.append_expr(m.allocator, .{ .ty = u32_ty, .category = .value, .data = .{ .int_lit = 10 } });
    _ = try func.append_expr(m.allocator, .{ .ty = f32_ty, .category = .value, .data = .{ .index = .{ .base = 0, .index = 1 } } });
    try m.functions.append(m.allocator, func);
    try robustness.apply(testing.allocator, &m, .{});
    const fn_ref = &m.functions.items[0];
    try testing.expect(fn_ref.exprs.items[2].data.index.index != 1);
    var found_3 = false;
    for (fn_ref.exprs.items) |e| {
        if (e.data == .int_lit and e.data.int_lit == 3) found_3 = true;
    }
    try testing.expect(found_3);
}

// ---- Robustness: texture coordinate clamping ----

test "robustness: textureLoad gets coordinate clamped" {
    var m = ir.Module.init(testing.allocator);
    defer m.deinit();
    const f32_ty = try m.types.intern(.{ .scalar = .f32 });
    const u32_ty = try m.types.intern(.{ .scalar = .u32 });
    const tex_ty = try m.types.intern(.{ .texture_2d = f32_ty });
    const vec2u = try m.types.intern(.{ .vector = .{ .elem = u32_ty, .len = 2 } });
    try m.globals.append(m.allocator, .{
        .name = try ir.dup_string(m.allocator, "tex"),
        .ty = tex_ty,
        .class = .var_,
        .addr_space = .handle,
        .binding = .{ .group = 0, .binding = 0 },
    });
    var func = ir.Function{
        .name = try ir.dup_string(m.allocator, "main"),
        .return_type = try m.types.intern(.{ .scalar = .void }),
        .stage = .compute,
    };
    _ = try func.append_expr(m.allocator, .{ .ty = tex_ty, .category = .ref, .data = .{ .global_ref = 0 } });
    _ = try func.append_expr(m.allocator, .{ .ty = vec2u, .category = .value, .data = .{ .int_lit = 0 } });
    _ = try func.append_expr(m.allocator, .{ .ty = u32_ty, .category = .value, .data = .{ .int_lit = 0 } });
    const args = try func.append_expr_args(m.allocator, &.{ 0, 1, 2 });
    const vec4f = try m.types.intern(.{ .vector = .{ .elem = f32_ty, .len = 4 } });
    _ = try func.append_expr(m.allocator, .{
        .ty = vec4f,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(m.allocator, "textureLoad"),
            .kind = .builtin,
            .args = args,
        } },
    });
    try m.functions.append(m.allocator, func);
    try robustness.apply(testing.allocator, &m, .{});
    const fn_ref = &m.functions.items[0];
    try testing.expect(fn_ref.expr_args.items[args.start + 1] != 1);
    var found_clamp = false;
    for (fn_ref.exprs.items) |e| {
        if (e.data == .call and std.mem.eql(u8, e.data.call.name, "clamp")) found_clamp = true;
    }
    try testing.expect(found_clamp);
}

// ---- Sema helpers: literal parsing ----

test "sema: parse_wgsl_int_literal" {
    try testing.expectEqual(@as(u32, 42), try sema_helpers.parse_wgsl_int_literal(u32, "42"));
    try testing.expectEqual(@as(u32, 42), try sema_helpers.parse_wgsl_int_literal(u32, "42u"));
    try testing.expectEqual(@as(u32, 42), try sema_helpers.parse_wgsl_int_literal(u32, "42i"));
    try testing.expectEqual(@as(u32, 255), try sema_helpers.parse_wgsl_int_literal(u32, "0xFF"));
    try testing.expectEqual(@as(u32, 10), try sema_helpers.parse_wgsl_int_literal(u32, "0b1010"));
    try testing.expectEqual(@as(u32, 63), try sema_helpers.parse_wgsl_int_literal(u32, "0o77"));
}

test "sema: parse_wgsl_float_literal" {
    try testing.expectEqual(@as(f64, 2.0), try sema_helpers.parse_wgsl_float_literal("2.0f"));
    try testing.expectEqual(@as(f64, 3.5), try sema_helpers.parse_wgsl_float_literal("3.5h"));
    try testing.expectEqual(@as(f64, 1.0), try sema_helpers.parse_wgsl_float_literal("1.0"));
}

test "sema: literal suffix classification" {
    try testing.expectEqual(sema_helpers.int_literal_suffix("42u"), .u);
    try testing.expectEqual(sema_helpers.int_literal_suffix("42i"), .i);
    try testing.expectEqual(sema_helpers.int_literal_suffix("42"), .none);
    try testing.expectEqual(sema_helpers.float_literal_suffix("1.0f"), .f);
    try testing.expectEqual(sema_helpers.float_literal_suffix("1.0h"), .h);
    try testing.expectEqual(sema_helpers.float_literal_suffix("1.0"), .none);
}

// ---- Sema helpers: address space / access ----

test "sema: parse_address_space" {
    try testing.expectEqual(ir.AddressSpace.storage, try sema_helpers.parse_address_space("storage"));
    try testing.expectEqual(ir.AddressSpace.uniform, try sema_helpers.parse_address_space("uniform"));
    try testing.expectEqual(ir.AddressSpace.workgroup, try sema_helpers.parse_address_space("workgroup"));
    try testing.expectEqual(ir.AddressSpace.private, try sema_helpers.parse_address_space("private"));
    try testing.expectEqual(ir.AddressSpace.function, try sema_helpers.parse_address_space("function"));
    try testing.expectError(error.InvalidAttribute, sema_helpers.parse_address_space("bogus"));
}

test "sema: parse_access" {
    try testing.expectEqual(ir.AccessMode.read, try sema_helpers.parse_access("read"));
    try testing.expectEqual(ir.AccessMode.write, try sema_helpers.parse_access("write"));
    try testing.expectEqual(ir.AccessMode.read_write, try sema_helpers.parse_access("read_write"));
    try testing.expectError(error.InvalidAttribute, sema_helpers.parse_access("execute"));
}

// ---- Sema helpers: vector swizzle ----

test "sema: parse_vector_swizzle" {
    const xy = try sema_helpers.parse_vector_swizzle("xy", 4);
    try testing.expectEqual(@as(u8, 2), xy.len);
    try testing.expectEqual(@as(u32, 0), xy.indices[0]);
    try testing.expectEqual(@as(u32, 1), xy.indices[1]);
    const rgba = try sema_helpers.parse_vector_swizzle("rgba", 4);
    try testing.expectEqual(@as(u8, 4), rgba.len);
    try testing.expectEqual(@as(u32, 3), rgba.indices[3]);
    try testing.expectError(error.InvalidSwizzle, sema_helpers.parse_vector_swizzle("xg", 4));
    try testing.expectError(error.InvalidSwizzle, sema_helpers.parse_vector_swizzle("w", 3));
    try testing.expectError(error.InvalidSwizzle, sema_helpers.parse_vector_swizzle("", 4));
}

// ---- Sema helpers: texture format ----

test "sema: parse_storage_texture_format" {
    try testing.expectEqual(ir.TextureFormat.rgba8unorm, try sema_helpers.parse_storage_texture_format("rgba8unorm"));
    try testing.expectEqual(ir.TextureFormat.r32float, try sema_helpers.parse_storage_texture_format("r32float"));
    try testing.expectError(error.InvalidAttribute, sema_helpers.parse_storage_texture_format("rgb8"));
}

// ---- Sema type utilities ----

test "sema: is_handle_type" {
    try testing.expect(sema_typeutils.is_handle_type(.{ .sampler = {} }));
    try testing.expect(sema_typeutils.is_handle_type(.{ .texture_2d = 0 }));
    try testing.expect(!sema_typeutils.is_handle_type(.{ .scalar = .f32 }));
    try testing.expect(!sema_typeutils.is_handle_type(.{ .array = .{ .elem = 0, .len = 4 } }));
}

fn initTestSemaModule() !struct { module: sema.SemanticModule } {
    var module = sema.SemanticModule{
        .allocator = testing.allocator,
        .tree = undefined,
        .types = ir.TypeStore.init(testing.allocator),
    };
    module.void_type = try module.types.intern(.{ .scalar = .void });
    module.bool_type = try module.types.intern(.{ .scalar = .bool });
    module.i32_type = try module.types.intern(.{ .scalar = .i32 });
    module.u32_type = try module.types.intern(.{ .scalar = .u32 });
    module.f32_type = try module.types.intern(.{ .scalar = .f32 });
    module.f16_type = try module.types.intern(.{ .scalar = .f16 });
    module.abstract_int_type = try module.types.intern(.{ .scalar = .abstract_int });
    module.abstract_float_type = try module.types.intern(.{ .scalar = .abstract_float });
    return .{ .module = module };
}

test "sema: bitcast_type_bits" {
    var s = try initTestSemaModule();
    defer s.module.types.deinit();
    try testing.expectEqual(@as(?u32, 32), sema_typeutils.bitcast_type_bits(&s.module, s.module.i32_type));
    try testing.expectEqual(@as(?u32, 32), sema_typeutils.bitcast_type_bits(&s.module, s.module.f32_type));
    try testing.expectEqual(@as(?u32, 16), sema_typeutils.bitcast_type_bits(&s.module, s.module.f16_type));
    const vec4f = try s.module.types.intern(.{ .vector = .{ .elem = s.module.f32_type, .len = 4 } });
    try testing.expectEqual(@as(?u32, 128), sema_typeutils.bitcast_type_bits(&s.module, vec4f));
}

test "sema: bitcast_types_compatible" {
    var s = try initTestSemaModule();
    defer s.module.types.deinit();
    try testing.expect(sema_typeutils.bitcast_types_compatible(&s.module, s.module.i32_type, s.module.u32_type));
    try testing.expect(sema_typeutils.bitcast_types_compatible(&s.module, s.module.f32_type, s.module.u32_type));
    try testing.expect(!sema_typeutils.bitcast_types_compatible(&s.module, s.module.f16_type, s.module.f32_type));
}

test "sema: materialize_inferred_local_type" {
    var s = try initTestSemaModule();
    defer s.module.types.deinit();
    try testing.expectEqual(s.module.i32_type, sema_typeutils.materialize_inferred_local_type(&s.module, s.module.abstract_int_type));
    try testing.expectEqual(s.module.f32_type, sema_typeutils.materialize_inferred_local_type(&s.module, s.module.abstract_float_type));
    try testing.expectEqual(s.module.i32_type, sema_typeutils.materialize_inferred_local_type(&s.module, s.module.i32_type));
}

test "sema: concrete_numeric_type coercion" {
    var s = try initTestSemaModule();
    defer s.module.types.deinit();
    try testing.expectEqual(s.module.i32_type, sema_helpers.concrete_numeric_type(&s.module, s.module.abstract_int_type, s.module.i32_type));
    try testing.expectEqual(s.module.i32_type, sema_helpers.concrete_numeric_type(&s.module, s.module.i32_type, s.module.abstract_int_type));
    try testing.expectEqual(s.module.f32_type, sema_helpers.concrete_numeric_type(&s.module, s.module.abstract_float_type, s.module.f32_type));
    try testing.expectEqual(s.module.f32_type, sema_helpers.concrete_numeric_type(&s.module, s.module.f32_type, s.module.f32_type));
}

// ---- IR utilities ----

test "ir: is_scalar" {
    var store = ir.TypeStore.init(testing.allocator);
    defer store.deinit();
    const f32_ty = try store.intern(.{ .scalar = .f32 });
    const u32_ty = try store.intern(.{ .scalar = .u32 });
    const vec_ty = try store.intern(.{ .vector = .{ .elem = f32_ty, .len = 4 } });
    try testing.expect(ir.is_scalar(&store, f32_ty, .f32));
    try testing.expect(ir.is_scalar(&store, u32_ty, .u32));
    try testing.expect(!ir.is_scalar(&store, f32_ty, .u32));
    try testing.expect(!ir.is_scalar(&store, vec_ty, .f32));
    try testing.expect(!ir.is_scalar(&store, ir.INVALID_TYPE, .f32));
}

test "ir: dup_string" {
    const copy = try ir.dup_string(testing.allocator, "hello");
    defer testing.allocator.free(copy);
    try testing.expectEqualStrings("hello", copy);
}

// ---- Token lookup ----

test "token: lookupIdent" {
    try testing.expectEqual(Tag.kw_fn, token_mod.lookupIdent("fn"));
    try testing.expectEqual(Tag.kw_var, token_mod.lookupIdent("var"));
    try testing.expectEqual(Tag.kw_vec4f, token_mod.lookupIdent("vec4f"));
    try testing.expectEqual(Tag.kw_f32, token_mod.lookupIdent("f32"));
    try testing.expectEqual(Tag.ident, token_mod.lookupIdent("myVariable"));
}
