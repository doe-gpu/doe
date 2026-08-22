// shader_emit_test.zig - Unit tests for vertex and fragment MSL emitters.

const support = @import("shader_emit_test_support.zig");
const std = support.std;
const ir = support.ir;
const emit_msl_vertex = support.emit_msl_vertex;
const emit_msl_fragment = support.emit_msl_fragment;
const emit_msl_shared = support.emit_msl_shared;
const testing = support.testing;
const allocator = support.allocator;
const make_module_with_types = support.make_module_with_types;
const output_str = support.output_str;
const build_vertex_module = support.build_vertex_module;
const build_fragment_module = support.build_fragment_module;
const cleanup_function = support.cleanup_function;

// ============================================================
// emit_msl_vertex tests
// ============================================================

test "vertex emitter: output struct with position and user location" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });
    const vec2f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 2 } });

    var function = try build_vertex_module(
        &module,
        "VertOut",
        &.{
            .{ .name = "clip_pos", .ty = vec4f_type, .io = .{ .builtin = .position } },
            .{ .name = "uv", .ty = vec2f_type, .io = .{ .location = 0 } },
        },
        &.{},
        "vs_main",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "struct VertOut_vertex_out") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[position]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[user(loc0)]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[vertex]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "VertOut_vertex_out vs_main") != null);
}

test "vertex emitter: invariant position attribute" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_vertex_module(
        &module,
        "InvOut",
        &.{
            .{ .name = "pos", .ty = vec4f_type, .io = .{ .builtin = .position, .invariant = true } },
        },
        &.{},
        "vs_invariant",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "[[position, invariant]]") != null);
}

test "vertex emitter: vertex_id and instance_id builtin parameters" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const u32_type = try module.types.intern(.{ .scalar = .u32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_vertex_module(
        &module,
        "PosOut",
        &.{
            .{ .name = "pos", .ty = vec4f_type, .io = .{ .builtin = .position } },
        },
        &.{
            .{ .name = "vid", .ty = u32_type, .io = .{ .builtin = .vertex_index } },
            .{ .name = "iid", .ty = u32_type, .io = .{ .builtin = .instance_index } },
        },
        "vs_builtins",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "[[vertex_id]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[instance_id]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "uint vid [[vertex_id]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "uint iid [[instance_id]]") != null);
}

test "vertex emitter: attribute(N) for location-decorated scalar params" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });
    const vec2f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 2 } });

    var function = try build_vertex_module(
        &module,
        "SimpleOut",
        &.{
            .{ .name = "pos", .ty = vec4f_type, .io = .{ .builtin = .position } },
        },
        &.{
            .{ .name = "position", .ty = vec4f_type, .io = .{ .location = 0 } },
            .{ .name = "texcoord", .ty = vec2f_type, .io = .{ .location = 1 } },
            .{ .name = "color", .ty = vec4f_type, .io = .{ .location = 2 } },
        },
        "vs_attrs",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "[[attribute(0)]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[attribute(1)]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[attribute(2)]]") != null);
}

test "vertex emitter: struct input parameter gets [[stage_in]]" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });
    const vec2f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 2 } });

    var input_struct = ir.StructDef{ .name = try ir.dup_string(allocator, "VertIn") };
    errdefer input_struct.deinit(allocator);
    try input_struct.fields.append(allocator, .{ .name = try ir.dup_string(allocator, "pos"), .ty = vec4f_type, .io = .{ .location = 0 } });
    try input_struct.fields.append(allocator, .{ .name = try ir.dup_string(allocator, "uv"), .ty = vec2f_type, .io = .{ .location = 1 } });
    try module.structs.append(allocator, input_struct);
    const input_struct_id: ir.StructId = @intCast(module.structs.items.len - 1);
    const input_struct_type = try module.types.intern(.{ .struct_ = input_struct_id });

    var function = try build_vertex_module(
        &module,
        "VertOut",
        &.{
            .{ .name = "clip_pos", .ty = vec4f_type, .io = .{ .builtin = .position } },
            .{ .name = "uv", .ty = vec2f_type, .io = .{ .location = 0 } },
        },
        &.{
            .{ .name = "input", .ty = input_struct_type, .io = null },
        },
        "vs_struct_in",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "VertIn input [[stage_in]]") != null);
}

test "vertex emitter: no params emits empty parameter list" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_vertex_module(
        &module,
        "MinOut",
        &.{
            .{ .name = "pos", .ty = vec4f_type, .io = .{ .builtin = .position } },
        },
        &.{},
        "vs_empty",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "vs_empty()") != null);
}

test "vertex emitter: multiple output locations with interpolation" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });
    const vec2f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 2 } });

    var function = try build_vertex_module(
        &module,
        "InterpOut",
        &.{
            .{ .name = "pos", .ty = vec4f_type, .io = .{ .builtin = .position } },
            .{ .name = "uv", .ty = vec2f_type, .io = .{ .location = 0, .interpolation = .perspective } },
            .{ .name = "flat_id", .ty = f32_type, .io = .{ .location = 1, .interpolation = .flat } },
            .{ .name = "linear_v", .ty = vec2f_type, .io = .{ .location = 2, .interpolation = .linear } },
        },
        &.{},
        "vs_interp",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "[[user(loc0)]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[flat]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[center_no_perspective]]") != null);
}

test "vertex emitter: void return type is rejected as InvalidIr" {
    var module = make_module_with_types();
    defer module.deinit();

    const void_type = try module.types.intern(.{ .scalar = .void });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "vs_void"),
        .return_type = void_type,
        .stage = .vertex,
    };
    const return_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{return_stmt});
    const block_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    function.root_stmt = block_stmt;
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    const err = emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    try testing.expectError(error.InvalidIr, err);
}

test "vertex emitter: output too large returns error" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_vertex_module(
        &module,
        "BigOut",
        &.{
            .{ .name = "pos", .ty = vec4f_type, .io = .{ .builtin = .position } },
        },
        &.{},
        "vs_small_buf",
    );
    defer cleanup_function(&function);

    var buf: [8]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    const err = emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    try testing.expectError(error.OutputTooLarge, err);
}

test "vertex emitter: unsupported builtin input returns UnsupportedBuiltin" {
    var module = make_module_with_types();
    defer module.deinit();

    const u32_type = try module.types.intern(.{ .scalar = .u32 });
    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_vertex_module(
        &module,
        "UnsupportedVertexBuiltinOut",
        &.{
            .{ .name = "pos", .ty = vec4f_type, .io = .{ .builtin = .position } },
        },
        &.{
            .{ .name = "front", .ty = u32_type, .io = .{ .builtin = .front_facing } },
        },
        "vs_unsupported_builtin",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    const err = emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    try testing.expectError(error.UnsupportedBuiltin, err);
}

test "vertex emitter: main function name is renamed to main_vertex" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_vertex_module(
        &module,
        "MainOut",
        &.{
            .{ .name = "pos", .ty = vec4f_type, .io = .{ .builtin = .position } },
        },
        &.{},
        "main",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_vertex.emit_vertex_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "main_vertex(") != null);
}

// ============================================================
// emit_msl_fragment tests
// ============================================================

test "fragment emitter: MRT output struct with color(N) attributes" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_fragment_module(
        &module,
        "FragOut",
        &.{
            .{ .name = "color0", .ty = vec4f_type, .io = .{ .location = 0 } },
            .{ .name = "color1", .ty = vec4f_type, .io = .{ .location = 1 } },
            .{ .name = "color2", .ty = vec4f_type, .io = .{ .location = 2 } },
        },
        &.{},
        "fs_mrt",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "struct FragOut_fragment_out") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[color(0)]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[color(1)]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[color(2)]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[fragment]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "FragOut_fragment_out fs_mrt") != null);
}

test "fragment emitter: frag_depth output maps to [[depth(any)]]" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_fragment_module(
        &module,
        "DepthOut",
        &.{
            .{ .name = "color", .ty = vec4f_type, .io = .{ .location = 0 } },
            .{ .name = "depth", .ty = f32_type, .io = .{ .builtin = .frag_depth } },
        },
        &.{},
        "fs_depth",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "[[depth(any)]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[color(0)]]") != null);
}

test "fragment emitter: sample_mask output attribute" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const u32_type = try module.types.intern(.{ .scalar = .u32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_fragment_module(
        &module,
        "MaskOut",
        &.{
            .{ .name = "color", .ty = vec4f_type, .io = .{ .location = 0 } },
            .{ .name = "mask", .ty = u32_type, .io = .{ .builtin = .sample_mask } },
        },
        &.{},
        "fs_mask",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "[[sample_mask]]") != null);
}

test "fragment emitter: builtin input parameters (front_facing, position, sample_id)" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const bool_type = try module.types.intern(.{ .scalar = .bool });
    const u32_type = try module.types.intern(.{ .scalar = .u32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_fragment_module(
        &module,
        "ColorOut",
        &.{
            .{ .name = "color", .ty = vec4f_type, .io = .{ .location = 0 } },
        },
        &.{
            .{ .name = "frag_coord", .ty = vec4f_type, .io = .{ .builtin = .position } },
            .{ .name = "is_front", .ty = bool_type, .io = .{ .builtin = .front_facing } },
            .{ .name = "sid", .ty = u32_type, .io = .{ .builtin = .sample_index } },
        },
        "fs_builtins",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "[[position]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[front_facing]]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "[[sample_id]]") != null);
}

test "fragment emitter: struct input parameter receives [[stage_in]] with _vertex_out suffix" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });
    const vec2f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 2 } });

    var varying_struct = ir.StructDef{ .name = try ir.dup_string(allocator, "Varyings") };
    errdefer varying_struct.deinit(allocator);
    try varying_struct.fields.append(allocator, .{ .name = try ir.dup_string(allocator, "pos"), .ty = vec4f_type, .io = .{ .builtin = .position } });
    try varying_struct.fields.append(allocator, .{ .name = try ir.dup_string(allocator, "uv"), .ty = vec2f_type, .io = .{ .location = 0 } });
    try module.structs.append(allocator, varying_struct);
    const varying_struct_id: ir.StructId = @intCast(module.structs.items.len - 1);
    const varying_struct_type = try module.types.intern(.{ .struct_ = varying_struct_id });

    var function = try build_fragment_module(
        &module,
        "FragColorOut",
        &.{
            .{ .name = "color", .ty = vec4f_type, .io = .{ .location = 0 } },
        },
        &.{
            .{ .name = "in", .ty = varying_struct_type, .io = null },
        },
        "fs_stage_in",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "Varyings_vertex_out in [[stage_in]]") != null);
}

test "fragment emitter: discard statement emits discard_fragment()" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_fragment_module(
        &module,
        "DiscardOut",
        &.{
            .{ .name = "color", .ty = vec4f_type, .io = .{ .location = 0 } },
        },
        &.{},
        "fs_discard",
    );
    defer cleanup_function(&function);

    function.stmts.items.len = 0;
    function.stmt_children.items.len = 0;
    const discard_stmt = try function.append_stmt(allocator, .{ .discard_ = {} });
    const return_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{ discard_stmt, return_stmt });
    const block_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    function.root_stmt = block_stmt;

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "discard_fragment()") != null);
}

test "fragment emitter: void return type is rejected as InvalidIr" {
    var module = make_module_with_types();
    defer module.deinit();

    const void_type = try module.types.intern(.{ .scalar = .void });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "fs_void"),
        .return_type = void_type,
        .stage = .fragment,
    };
    const return_stmt = try function.append_stmt(allocator, .{ .return_ = null });
    const block_range = try function.append_stmt_children(allocator, &.{return_stmt});
    const block_stmt = try function.append_stmt(allocator, .{ .block = block_range });
    function.root_stmt = block_stmt;
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    const err = emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    try testing.expectError(error.InvalidIr, err);
}

test "fragment emitter: unsupported builtin input returns UnsupportedBuiltin" {
    var module = make_module_with_types();
    defer module.deinit();

    const u32_type = try module.types.intern(.{ .scalar = .u32 });
    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_fragment_module(
        &module,
        "UnsupportedFragmentBuiltinOut",
        &.{
            .{ .name = "color", .ty = vec4f_type, .io = .{ .location = 0 } },
        },
        &.{
            .{ .name = "vertex_id", .ty = u32_type, .io = .{ .builtin = .vertex_index } },
        },
        "fs_unsupported_builtin",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    const err = emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    try testing.expectError(error.UnsupportedBuiltin, err);
}

test "fragment emitter: main function name is renamed to main_fragment" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });

    var function = try build_fragment_module(
        &module,
        "MainFragOut",
        &.{
            .{ .name = "color", .ty = vec4f_type, .io = .{ .location = 0 } },
        },
        &.{},
        "main",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "main_fragment(") != null);
}

test "fragment emitter: location-decorated scalar input gets [[user(locN)]]" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const vec4f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 4 } });
    const vec2f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 2 } });

    var function = try build_fragment_module(
        &module,
        "LocFragOut",
        &.{
            .{ .name = "color", .ty = vec4f_type, .io = .{ .location = 0 } },
        },
        &.{
            .{ .name = "uv", .ty = vec2f_type, .io = .{ .location = 3 } },
        },
        "fs_loc_in",
    );
    defer cleanup_function(&function);

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var indent: usize = 0;
    try emit_msl_fragment.emit_fragment_function(&module, function, &buf, &pos, &indent);
    const result = output_str(&buf, pos);

    try testing.expect(std.mem.indexOf(u8, result, "float2 uv [[user(loc3)]]") != null);
}

// ============================================================
// emit_msl_shared: min/max/clamp type coercion
// ============================================================

test "shared: min with mismatched types emits cast to result type" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const i32_type = try module.types.intern(.{ .scalar = .i32 });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn"),
        .return_type = try module.types.intern(.{ .scalar = .void }),
        .stage = null,
    };
    defer cleanup_function(&function);

    // Build: min(param_i32, literal_f32) -> f32
    // arg0 is i32 param, arg1 is f32 literal. Result type is f32.
    try function.params.append(allocator, .{
        .name = try ir.dup_string(allocator, "x"),
        .ty = i32_type,
        .io = null,
    });
    const arg0 = try function.append_expr(allocator, .{
        .ty = i32_type,
        .category = .value,
        .data = .{ .param_ref = 0 },
    });
    const arg1 = try function.append_expr(allocator, .{
        .ty = f32_type,
        .category = .value,
        .data = .{ .float_lit = 1.0 },
    });
    const args_range = try function.append_expr_args(allocator, &.{ arg0, arg1 });
    const call_expr = try function.append_expr(allocator, .{
        .ty = f32_type,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "min"),
            .kind = .builtin,
            .args = args_range,
        } },
    });

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emit_msl_shared.write_expr(&module, function, call_expr, &buf, &pos);
    const result = output_str(&buf, pos);

    // arg0 (i32) should be cast to float; arg1 (f32) matches, no cast needed.
    try testing.expect(std.mem.indexOf(u8, result, "min(float(x), ") != null);
    // Verify the cast wrapped arg0 but not arg1 (which already has the correct type).
    try testing.expect(std.mem.indexOf(u8, result, "float(1)") == null);
}

test "shared: max with matching types emits no casts" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn"),
        .return_type = try module.types.intern(.{ .scalar = .void }),
        .stage = null,
    };
    defer cleanup_function(&function);

    try function.params.append(allocator, .{
        .name = try ir.dup_string(allocator, "a"),
        .ty = f32_type,
        .io = null,
    });
    try function.params.append(allocator, .{
        .name = try ir.dup_string(allocator, "b"),
        .ty = f32_type,
        .io = null,
    });
    const arg0 = try function.append_expr(allocator, .{
        .ty = f32_type,
        .category = .value,
        .data = .{ .param_ref = 0 },
    });
    const arg1 = try function.append_expr(allocator, .{
        .ty = f32_type,
        .category = .value,
        .data = .{ .param_ref = 1 },
    });
    const args_range = try function.append_expr_args(allocator, &.{ arg0, arg1 });
    const call_expr = try function.append_expr(allocator, .{
        .ty = f32_type,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "max"),
            .kind = .builtin,
            .args = args_range,
        } },
    });

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emit_msl_shared.write_expr(&module, function, call_expr, &buf, &pos);
    const result = output_str(&buf, pos);

    // Both args match result type, no casts needed.
    try testing.expectEqualStrings("max(a, b)", result);
}

test "shared: clamp with abstract_int args emits casts to concrete type" {
    var module = make_module_with_types();
    defer module.deinit();

    const u32_type = try module.types.intern(.{ .scalar = .u32 });
    const abstract_int_type = try module.types.intern(.{ .scalar = .abstract_int });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn"),
        .return_type = try module.types.intern(.{ .scalar = .void }),
        .stage = null,
    };
    defer cleanup_function(&function);

    try function.params.append(allocator, .{
        .name = try ir.dup_string(allocator, "v"),
        .ty = u32_type,
        .io = null,
    });
    const arg0 = try function.append_expr(allocator, .{
        .ty = u32_type,
        .category = .value,
        .data = .{ .param_ref = 0 },
    });
    const arg1 = try function.append_expr(allocator, .{
        .ty = abstract_int_type,
        .category = .value,
        .data = .{ .int_lit = 0 },
    });
    const arg2 = try function.append_expr(allocator, .{
        .ty = abstract_int_type,
        .category = .value,
        .data = .{ .int_lit = 255 },
    });
    const args_range = try function.append_expr_args(allocator, &.{ arg0, arg1, arg2 });
    const call_expr = try function.append_expr(allocator, .{
        .ty = u32_type,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "clamp"),
            .kind = .builtin,
            .args = args_range,
        } },
    });

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emit_msl_shared.write_expr(&module, function, call_expr, &buf, &pos);
    const result = output_str(&buf, pos);

    // arg0 matches u32, no cast. arg1 and arg2 are abstract_int, should be cast to uint.
    try testing.expect(std.mem.indexOf(u8, result, "clamp(v, uint(0), uint(255))") != null);
}

test "shared: min with vec types emits vector cast" {
    var module = make_module_with_types();
    defer module.deinit();

    const f32_type = try module.types.intern(.{ .scalar = .f32 });
    const i32_type = try module.types.intern(.{ .scalar = .i32 });
    const vec3f_type = try module.types.intern(.{ .vector = .{ .elem = f32_type, .len = 3 } });
    const vec3i_type = try module.types.intern(.{ .vector = .{ .elem = i32_type, .len = 3 } });

    var function = ir.Function{
        .name = try ir.dup_string(allocator, "test_fn"),
        .return_type = try module.types.intern(.{ .scalar = .void }),
        .stage = null,
    };
    defer cleanup_function(&function);

    try function.params.append(allocator, .{
        .name = try ir.dup_string(allocator, "a"),
        .ty = vec3f_type,
        .io = null,
    });
    try function.params.append(allocator, .{
        .name = try ir.dup_string(allocator, "b"),
        .ty = vec3i_type,
        .io = null,
    });
    const arg0 = try function.append_expr(allocator, .{
        .ty = vec3f_type,
        .category = .value,
        .data = .{ .param_ref = 0 },
    });
    const arg1 = try function.append_expr(allocator, .{
        .ty = vec3i_type,
        .category = .value,
        .data = .{ .param_ref = 1 },
    });
    const args_range = try function.append_expr_args(allocator, &.{ arg0, arg1 });
    const call_expr = try function.append_expr(allocator, .{
        .ty = vec3f_type,
        .category = .value,
        .data = .{ .call = .{
            .name = try ir.dup_string(allocator, "min"),
            .kind = .builtin,
            .args = args_range,
        } },
    });

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    try emit_msl_shared.write_expr(&module, function, call_expr, &buf, &pos);
    const result = output_str(&buf, pos);

    // arg0 matches float3, no cast. arg1 is int3, should be cast to float3.
    try testing.expect(std.mem.indexOf(u8, result, "min(a, float3(b))") != null);
}

// ============================================================
// emit_msl_shared function name helpers
// ============================================================

test "shared: vertex_function_name renames main" {
    try testing.expectEqualStrings("main_vertex", emit_msl_shared.vertex_function_name("main"));
    try testing.expectEqualStrings("vs_main", emit_msl_shared.vertex_function_name("vs_main"));
    try testing.expectEqualStrings("custom", emit_msl_shared.vertex_function_name("custom"));
}

test "shared: fragment_function_name renames main" {
    try testing.expectEqualStrings("main_fragment", emit_msl_shared.fragment_function_name("main"));
    try testing.expectEqualStrings("fs_main", emit_msl_shared.fragment_function_name("fs_main"));
    try testing.expectEqualStrings("custom", emit_msl_shared.fragment_function_name("custom"));
}
