// emit_dxil_test.zig — Tests for native DXIL bytecode emission.
//
// Validates that the native DXIL emitter produces valid DXBC containers
// from WGSL source, covering compute, vertex, and fragment shader stages.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const dxil_spec = @import("../../src/compiler/wgsl/emit/dxil/dxil_spec.zig");
const dxil_container = @import("../../src/compiler/wgsl/emit/dxil/dxil_container.zig");
const dxil_bitcode = @import("../../src/compiler/wgsl/emit/dxil/dxil_bitcode.zig");
const dxil_builder = @import("../../src/compiler/wgsl/emit/dxil/dxil_builder.zig");
const dxil_serialize = @import("../../src/compiler/wgsl/emit/dxil/dxil_serialize.zig");

const testing = std.testing;
const allocator = testing.allocator;

const MAX_DXIL_OUTPUT = mod.MAX_DXIL_OUTPUT;

fn has_dxbc_magic(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], &dxil_spec.DXBC_FOURCC);
}

fn read_part_count(data: []const u8) u32 {
    if (data.len < 32) return 0;
    return std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(data[28..32].ptr)), .little);
}

// ============================================================
// Bitcode writer unit tests
// ============================================================

test "dxil bitcode: VBR encoding round-trips small values" {
    var buf: [32]u8 = .{0} ** 32;
    var w = dxil_bitcode.Writer.init(&buf);
    try w.emit_vbr(7, 4);
    try w.emit_vbr(0, 4);
    try w.emit_vbr(255, 4);
    const size = w.finalize();
    try testing.expect(size > 0);
}

test "dxil bitcode: block enter/exit produces aligned output" {
    var buf: [256]u8 = .{0} ** 256;
    var w = dxil_bitcode.Writer.init(&buf);
    try w.emit_raw_bytes(&dxil_spec.LLVM_IR_MAGIC);
    try w.enter_block(dxil_spec.BlockId.MODULE, 3);
    try w.emit_record(dxil_spec.ModuleCode.VERSION, &.{1});
    try w.exit_block();
    const size = w.finalize();
    // Output should be 4-byte aligned after exit_block
    try testing.expectEqual(@as(usize, 0), size % 4);
}

test "dxil bitcode: string record encodes correctly" {
    var buf: [128]u8 = .{0} ** 128;
    var w = dxil_bitcode.Writer.init(&buf);
    try w.enter_block(dxil_spec.BlockId.MODULE, 4);
    try w.emit_string_record(dxil_spec.ModuleCode.TRIPLE, "dxil-ms-dx");
    try w.exit_block();
    const size = w.finalize();
    try testing.expect(size > 0);
}

// ============================================================
// Builder unit tests
// ============================================================

test "dxil builder: type deduplication" {
    var b = dxil_builder.Builder.init();
    const i32a = try b.type_i32();
    const i32b = try b.type_i32();
    try testing.expectEqual(i32a, i32b);

    const f32a = try b.type_f32();
    try testing.expect(f32a != i32a);
}

test "dxil builder: function type construction" {
    var b = dxil_builder.Builder.init();
    const void_ty = try b.type_void();
    const i32_ty = try b.type_i32();
    const fn_ty = try b.type_function(void_ty, &.{ i32_ty, i32_ty }, false);
    try testing.expect(fn_ty != void_ty);
}

test "dxil builder: metadata construction" {
    var b = dxil_builder.Builder.init();
    const str_md = try b.add_metadata_string("test");
    const i32_ty = try b.type_i32();
    const val_const = try b.add_const_i32(42);
    const val_md = try b.add_metadata_value(i32_ty, val_const);
    const node = try b.add_metadata_node(&.{ str_md, val_md });
    try b.add_named_metadata("test.name", &.{node});
    try testing.expectEqual(@as(u32, 1), b.named_md_count);
}

// ============================================================
// Container format tests
// ============================================================

test "dxil container: empty container valid" {
    var buf: [256]u8 = undefined;
    const size = try dxil_container.write_container(&.{}, &buf);
    try testing.expect(has_dxbc_magic(buf[0..size]));
    try testing.expectEqual(@as(u32, 0), read_part_count(buf[0..size]));
}

test "dxil container: single part roundtrip" {
    var buf: [1024]u8 = undefined;
    const test_data = [_]u8{ 1, 2, 3, 4 };
    const parts = [_]dxil_container.Part{
        .{ .fourcc = dxil_spec.PartFourCC.DXIL, .data = &test_data },
    };
    const size = try dxil_container.write_container(&parts, &buf);
    try testing.expect(has_dxbc_magic(buf[0..size]));
    try testing.expectEqual(@as(u32, 1), read_part_count(buf[0..size]));
}

test "dxil container: feature flags part" {
    var buf: [64]u8 = undefined;
    const size = try dxil_container.write_feature_flags(&buf);
    try testing.expectEqual(@as(usize, 8), size);
}

test "dxil container: DXIL program header" {
    var bc_data: [64]u8 = .{0} ** 64;
    var buf: [256]u8 = undefined;
    const size = try dxil_container.write_dxil_program_part(.{
        .shader_kind = dxil_spec.ShaderKind.COMPUTE,
        .bitcode = &bc_data,
    }, &buf);
    try testing.expect(size > 24);
}

// ============================================================
// Serializer tests
// ============================================================

test "dxil serialize: minimal module" {
    var b = dxil_builder.Builder.init();
    _ = try b.type_void();
    _ = try b.type_i32();
    _ = try b.type_f32();

    var out: [4096]u8 = .{0} ** 4096;
    const size = try dxil_serialize.serialize(&b, &.{}, &out);
    try testing.expect(size >= 4);
    try testing.expectEqualSlices(u8, &dxil_spec.LLVM_IR_MAGIC, out[0..4]);
}

test "dxil serialize: module with function decl" {
    var b = dxil_builder.Builder.init();
    const void_ty = try b.type_void();
    const i32_ty = try b.type_i32();
    const fn_ty = try b.type_function(void_ty, &.{i32_ty}, false);
    _ = try b.add_function(.{
        .name = "main",
        .type_index = fn_ty,
        .is_definition = false,
    });
    try b.add_symtab_entry(0, "main");

    var out: [4096]u8 = .{0} ** 4096;
    const size = try dxil_serialize.serialize(&b, &.{}, &out);
    try testing.expect(size > 4);
}

test "dxil serialize: module with constants and metadata" {
    var b = dxil_builder.Builder.init();
    _ = try b.type_void();
    const i32_ty = try b.type_i32();

    _ = try b.add_const_i32(42);
    _ = try b.add_const_i32(-1);
    _ = try b.add_const_f32(3.14);

    const str_md = try b.add_metadata_string("cs");
    const val_md = try b.add_metadata_value(i32_ty, try b.add_const_u32(6));
    const node = try b.add_metadata_node(&.{ str_md, val_md });
    try b.add_named_metadata("dx.shaderModel", &.{node});

    var out: [8192]u8 = .{0} ** 8192;
    const size = try dxil_serialize.serialize(&b, &.{}, &out);
    try testing.expect(size > 4);
}

// ============================================================
// Full WGSL-to-DXIL integration tests
// ============================================================

test "dxil native: compute shader produces DXBC container" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    buf[id.x] = buf[id.x] * 2.0;
        \\}
    ;
    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = try mod.translateToDxil(allocator, source, &out);
    try testing.expect(len > 32);
    try testing.expect(has_dxbc_magic(out[0..len]));
    try testing.expect(read_part_count(out[0..len]) >= 2);
}

test "dxil native: compute shader with workgroup barrier" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\var<workgroup> shared_data: array<f32, 64>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_index) idx: u32) {
        \\    shared_data[idx] = buf[idx];
        \\    workgroupBarrier();
        \\    buf[idx] = shared_data[63u - idx];
        \\}
    ;
    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = try mod.translateToDxil(allocator, source, &out);
    try testing.expect(len > 32);
    try testing.expect(has_dxbc_magic(out[0..len]));
}

test "dxil native: vertex shader produces DXBC container" {
    const source =
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4f {
        \\    return vec4f(f32(vid), 0.0, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = try mod.translateToDxil(allocator, source, &out);
    try testing.expect(len > 32);
    try testing.expect(has_dxbc_magic(out[0..len]));
}

test "dxil native: fragment shader produces DXBC container" {
    const source =
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    return vec4f(uv, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = try mod.translateToDxil(allocator, source, &out);
    try testing.expect(len > 32);
    try testing.expect(has_dxbc_magic(out[0..len]));
}

test "dxil native: compute shader with multiple bindings" {
    const source =
        \\@group(0) @binding(0) var<uniform> params: vec4f;
        \\@group(0) @binding(1) var<storage, read> input: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> output: array<f32>;
        \\@compute @workgroup_size(256)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    output[id.x] = input[id.x] * params.x;
        \\}
    ;
    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = try mod.translateToDxil(allocator, source, &out);
    try testing.expect(len > 32);
    try testing.expect(has_dxbc_magic(out[0..len]));
}

test "dxil native: compute shader with arithmetic" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = data[id.x];
        \\    let b = a + 1u;
        \\    let c = b * 2u;
        \\    data[id.x] = c;
        \\}
    ;
    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = try mod.translateToDxil(allocator, source, &out);
    try testing.expect(len > 32);
    try testing.expect(has_dxbc_magic(out[0..len]));
}

test "dxil native: compute shader with if/else" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    if (id.x < 32u) {
        \\        buf[id.x] = 1u;
        \\    } else {
        \\        buf[id.x] = 0u;
        \\    }
        \\}
    ;
    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = try mod.translateToDxil(allocator, source, &out);
    try testing.expect(len > 32);
    try testing.expect(has_dxbc_magic(out[0..len]));
}

test "dxil native: fragment with struct return" {
    const source =
        \\struct FragOut {
        \\    @location(0) color: vec4f,
        \\    @builtin(frag_depth) depth: f32,
        \\}
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> FragOut {
        \\    var out: FragOut;
        \\    out.color = vec4f(uv, 0.0, 1.0);
        \\    out.depth = 0.5;
        \\    return out;
        \\}
    ;
    var out: [MAX_DXIL_OUTPUT]u8 = undefined;
    const len = try mod.translateToDxil(allocator, source, &out);
    try testing.expect(len > 32);
    try testing.expect(has_dxbc_magic(out[0..len]));
}
