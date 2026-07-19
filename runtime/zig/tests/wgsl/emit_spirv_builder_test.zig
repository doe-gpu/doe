// emit_spirv_builder_test.zig — SPIR-V header, builder, binding, and compute emission tests.

const std = @import("std");
const spirv = @import("../../src/compiler/wgsl/emit/spirv/spirv_builder.zig");
const mod = @import("../../src/compiler/wgsl/mod.zig");

const testing = std.testing;
const allocator = testing.allocator;

const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;
const translateToSpirv = mod.translateToSpirv;

fn read_u32_le(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(bytes[offset .. offset + 4].ptr)), .little);
}

// ============================================================
// SPIR-V helpers
// ============================================================

fn find_spirv_word_sequence(binary: []const u8, needle: []const u32) bool {
    if (binary.len < needle.len * 4) return false;
    const word_count = binary.len / 4;
    if (word_count < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= word_count) : (i += 1) {
        var match = true;
        for (needle, 0..) |expected, j| {
            if (read_u32_le(binary, (i + j) * 4) != expected) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn has_spirv_variable_with_storage_class(binary: []const u8, storage_class: u32) bool {
    const word_count = binary.len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == spirv.Opcode.Variable and wc >= 4) {
            if (read_u32_le(binary, (i + 3) * 4) == storage_class) return true;
        }
        i += wc;
    }
    return false;
}

fn has_spirv_u32_constant_literal(binary: []const u8, literal: u32) bool {
    const word_count = binary.len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == spirv.Opcode.Constant and wc >= 4) {
            if (read_u32_le(binary, (i + 3) * 4) == literal) return true;
        }
        i += wc;
    }
    return false;
}

fn count_spirv_opcode(binary: []const u8, opcode: u16) u32 {
    const word_count = binary.len / 4;
    var i: usize = 5;
    var count: u32 = 0;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = @as(u16, @truncate(w));
        const wc = w >> 16;
        if (op == opcode) count += 1;
        i += wc;
    }
    return count;
}

test "spirv header: magic number is 0x07230203" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    const magic = read_u32_le(&out, 0);
    try testing.expectEqual(spirv.MAGIC, magic);
}

test "spirv header: version is 1.3 or later" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    const version = read_u32_le(&out, 4);
    try testing.expect(version >= 0x00010300);
}

test "spirv header: bound is nonzero" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    const bound = read_u32_le(&out, 12);
    try testing.expect(bound > 0);
}

test "spirv header: schema is 0" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len >= 20);
    const schema = read_u32_le(&out, 16);
    try testing.expectEqual(@as(u32, 0), schema);
}

test "spirv builder: type_void returns same ID on repeated calls" {
    var builder = spirv.Builder.init(allocator);
    defer builder.deinit();
    const id1 = try builder.type_void();
    const id2 = try builder.type_void();
    try testing.expectEqual(id1, id2);
}

test "spirv builder: distinct scalar types get distinct IDs" {
    var builder = spirv.Builder.init(allocator);
    defer builder.deinit();
    const void_id = try builder.type_void();
    const u32_id = try builder.type_u32();
    const i32_id = try builder.type_i32();
    const f32_id = try builder.type_f32();
    try testing.expect(void_id != u32_id);
    try testing.expect(u32_id != i32_id);
    try testing.expect(i32_id != f32_id);
}

test "spirv builder: vector types are deduplicated" {
    var builder = spirv.Builder.init(allocator);
    defer builder.deinit();
    const f32_id = try builder.type_f32();
    const vec3f_a = try builder.type_vector(f32_id, 3);
    const vec3f_b = try builder.type_vector(f32_id, 3);
    try testing.expectEqual(vec3f_a, vec3f_b);
}

test "spirv builder: different vector lengths get distinct IDs" {
    var builder = spirv.Builder.init(allocator);
    defer builder.deinit();
    const f32_id = try builder.type_f32();
    const vec2f = try builder.type_vector(f32_id, 2);
    const vec3f = try builder.type_vector(f32_id, 3);
    const vec4f = try builder.type_vector(f32_id, 4);
    try testing.expect(vec2f != vec3f);
    try testing.expect(vec3f != vec4f);
}

test "spirv builder: pointer types are deduplicated" {
    var builder = spirv.Builder.init(allocator);
    defer builder.deinit();
    const f32_id = try builder.type_f32();
    const ptr1 = try builder.type_pointer(spirv.StorageClass.Function, f32_id);
    const ptr2 = try builder.type_pointer(spirv.StorageClass.Function, f32_id);
    try testing.expectEqual(ptr1, ptr2);
}

test "spirv builder: pointer types differ by storage class" {
    var builder = spirv.Builder.init(allocator);
    defer builder.deinit();
    const f32_id = try builder.type_f32();
    const fn_ptr = try builder.type_pointer(spirv.StorageClass.Function, f32_id);
    const priv_ptr = try builder.type_pointer(spirv.StorageClass.Private, f32_id);
    try testing.expect(fn_ptr != priv_ptr);
}

test "spirv builder: constant deduplication" {
    var builder = spirv.Builder.init(allocator);
    defer builder.deinit();
    const c1 = try builder.const_u32(42);
    const c2 = try builder.const_u32(42);
    const c3 = try builder.const_u32(7);
    try testing.expectEqual(c1, c2);
    try testing.expect(c1 != c3);
}

test "spirv emit: repeated straight-line local reads share one load" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> out: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\  var x = id.x;
        \\  out[0] = x + x + x + x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len > 0);
    try testing.expect(count_spirv_opcode(out[0..len], spirv.Opcode.Load) <= 2);
}

test "spirv emit: repeated straight-line integer expression shares one result" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> out: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\  var x = id.x;
        \\  out[0] = (x + 1u) * (x + 1u);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    try testing.expect(len > 0);
    try testing.expect(count_spirv_opcode(out[0..len], spirv.Opcode.IAdd) <= 1);
}

test "spirv binding: OpDecorate DescriptorSet appears for bound resources" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32, 64>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[0] = 1.0;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    // OpDecorate has opcode 71. DescriptorSet = 34. Group = 0.
    // The instruction encoding is: (word_count << 16) | opcode, target_id, decoration, value
    // We search for opcode 71 with decoration 34 (DescriptorSet) and value 0.
    var found_descriptor_set = false;
    const word_count = len / 4;
    var i: usize = 5; // skip header
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 71 and wc >= 4) { // OpDecorate
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 34) { // DescriptorSet
                const value = read_u32_le(binary, (i + 3) * 4);
                if (value == 0) {
                    found_descriptor_set = true;
                    break;
                }
            }
        }
        i += wc;
    }
    try testing.expect(found_descriptor_set);
}

test "spirv binding: OpDecorate Binding appears for bound resources" {
    const source =
        \\@group(0) @binding(3) var<storage, read_write> data: array<f32, 64>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[0] = 1.0;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    var found_binding = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 71 and wc >= 4) {
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 33) { // Binding
                const value = read_u32_le(binary, (i + 3) * 4);
                if (value == 3) {
                    found_binding = true;
                    break;
                }
            }
        }
        i += wc;
    }
    try testing.expect(found_binding);
}

test "spirv const global: scalar literal emits constant without private variable" {
    const source =
        \\const kValue: u32 = 7u;
        \\@group(0) @binding(0) var<storage, read_write> result: array<u32, 1>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    result[0] = kValue;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(has_spirv_u32_constant_literal(binary, 7));
    try testing.expect(!has_spirv_variable_with_storage_class(binary, spirv.StorageClass.Private));
}

test "spirv private global: variable remains private storage" {
    const source =
        \\var<private> value: u32 = 1u;
        \\@group(0) @binding(0) var<storage, read_write> result: array<u32, 1>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    result[0] = value;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(has_spirv_variable_with_storage_class(binary, spirv.StorageClass.Private));
}

test "spirv private global: struct member value loads" {
    const source =
        \\struct State {
        \\    value: vec4f,
        \\}
        \\var<private> state: State;
        \\@group(0) @binding(0) var<storage, read_write> result: array<f32, 1>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    result[0] = state.value.x;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(has_spirv_variable_with_storage_class(binary, spirv.StorageClass.Private));
}

test "spirv compute: OpEntryPoint GLCompute appears" {
    const source =
        \\@compute @workgroup_size(4, 2, 1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    // OpEntryPoint = 15. ExecutionModel GLCompute = 5.
    var found_entry_point = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 15 and wc >= 3) { // OpEntryPoint
            const exec_model = read_u32_le(binary, (i + 1) * 4);
            if (exec_model == 5) { // GLCompute
                found_entry_point = true;
                break;
            }
        }
        i += wc;
    }
    try testing.expect(found_entry_point);
}

test "spirv compute: OpExecutionMode LocalSize appears with workgroup size" {
    const source =
        \\@compute @workgroup_size(8, 4, 2)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    // OpExecutionMode = 16. LocalSize = 17.
    var found_local_size = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 16 and wc >= 6) { // OpExecutionMode with at least 6 words
            const mode = read_u32_le(binary, (i + 2) * 4);
            if (mode == 17) { // LocalSize
                const x = read_u32_le(binary, (i + 3) * 4);
                const y = read_u32_le(binary, (i + 4) * 4);
                const z = read_u32_le(binary, (i + 5) * 4);
                if (x == 8 and y == 4 and z == 2) {
                    found_local_size = true;
                    break;
                }
            }
        }
        i += wc;
    }
    try testing.expect(found_local_size);
}

test "spirv compute: OpCapability Shader appears" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    // OpCapability = 17. Shader = 1.
    var found_shader_cap = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 17 and wc >= 2) {
            const cap = read_u32_le(binary, (i + 1) * 4);
            if (cap == 1) {
                found_shader_cap = true;
                break;
            }
        }
        i += wc;
    }
    try testing.expect(found_shader_cap);
}

test "spirv: OpMemoryModel Logical GLSL450 appears" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    // OpMemoryModel = 14. Logical = 0. GLSL450 = 1.
    var found_memory_model = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 14 and wc >= 3) {
            const addressing = read_u32_le(binary, (i + 1) * 4);
            const memory = read_u32_le(binary, (i + 2) * 4);
            if (addressing == 0 and memory == 1) {
                found_memory_model = true;
                break;
            }
        }
        i += wc;
    }
    try testing.expect(found_memory_model);
}

test "spirv builder: write_binary produces valid header" {
    var builder = spirv.Builder.init(allocator);
    defer builder.deinit();
    _ = try builder.type_void();
    const fn_type = try builder.type_function(try builder.type_void(), &.{});
    const fn_id = builder.reserve_id();
    try builder.emit_entry_point(fn_id, "main", &.{});
    try builder.emit_execution_mode_local_size(fn_id, 1, 1, 1);
    try builder.begin_function(try builder.type_void(), fn_id, fn_type);
    _ = try builder.label();
    try builder.append_function_inst(spirv.Opcode.Return, &.{});
    try builder.finish_function();

    var out: [4096]u8 = undefined;
    const len = try builder.write_binary(&out);
    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(&out, 0));
    try testing.expectEqual(@as(u32, 0), read_u32_le(&out, 16)); // schema
}

test "spirv binding: Block decoration emitted for uniform buffer" {
    const source =
        \\struct Params {
        \\    scale: f32,
        \\}
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let s = params.scale;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    // OpDecorate with Block decoration (2)
    var found_block = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 71 and wc >= 3) { // OpDecorate
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 2) { // Block
                found_block = true;
                break;
            }
        }
        i += wc;
    }
    try testing.expect(found_block);
}

test "spirv float comparison: f32 > emits OpFOrdGreaterThan (opcode 186)" {
    const source =
        \\@group(0) @binding(0) var<storage, read> data: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> result: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    if (data[0] > data[1]) {
        \\        result[0] = 1u;
        \\    }
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    // Scan for OpFOrdGreaterThan (opcode 186).
    // Instruction encoding: (word_count << 16) | opcode.
    var found_ford_gt = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 186) { // OpFOrdGreaterThan
            found_ford_gt = true;
            break;
        }
        i += wc;
    }
    try testing.expect(found_ford_gt);
}

test "spirv float comparison: f32 < emits OpFOrdLessThan (opcode 184)" {
    const source =
        \\@group(0) @binding(0) var<storage, read> data: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> result: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    if (data[0] < data[1]) {
        \\        result[0] = 1u;
        \\    }
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    var found_ford_lt = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 184) { // OpFOrdLessThan
            found_ford_lt = true;
            break;
        }
        i += wc;
    }
    try testing.expect(found_ford_lt);
}

test "spirv float comparison: f32 != emits OpFOrdNotEqual (opcode 182)" {
    const source =
        \\@group(0) @binding(0) var<storage, read> data: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> result: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    if (data[0] != data[1]) {
        \\        result[0] = 1u;
        \\    }
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    var found_ford_ne = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 182) { // OpFOrdNotEqual
            found_ford_ne = true;
            break;
        }
        i += wc;
    }
    try testing.expect(found_ford_ne);
}
