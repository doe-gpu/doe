// emit_spirv_stage_test.zig — SPIR-V vertex and fragment stage emission tests.

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
// HLSL type mapping tests (via IR construction)
// ============================================================

test "spirv vertex: produces valid binary with vertex entry point" {
    const source =
        \\struct VsOut {
        \\    @builtin(position) position: vec4f,
        \\    @location(0) uv: vec2f,
        \\}
        \\
        \\@vertex
        \\fn main(@builtin(vertex_index) vid: u32) -> VsOut {
        \\    var out: VsOut;
        \\    return out;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // OpEntryPoint Vertex (ExecutionModel = 0) should appear
    var found_vertex = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 15 and wc >= 3) {
            const exec_model = read_u32_le(binary, (i + 1) * 4);
            if (exec_model == 0) { // Vertex
                found_vertex = true;
                break;
            }
        }
        i += wc;
    }
    try testing.expect(found_vertex);
}

test "spirv fragment: produces valid binary with fragment entry point" {
    const source =
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    return vec4f(uv, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // OpEntryPoint Fragment (ExecutionModel = 4)
    var found_fragment = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 15 and wc >= 3) {
            const exec_model = read_u32_le(binary, (i + 1) * 4);
            if (exec_model == 4) { // Fragment
                found_fragment = true;
                break;
            }
        }
        i += wc;
    }
    try testing.expect(found_fragment);
}

test "spirv fragment: position input lowers to FragCoord rather than vertex Position" {
    const source =
        \\@fragment
        \\fn main(@builtin(position) position: vec4f) -> @location(0) vec4f {
        \\    return position;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    var found_frag_coord = false;
    var found_position = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const word = read_u32_le(binary, i * 4);
        const opcode = word & 0xFFFF;
        const instruction_words = word >> 16;
        if (opcode == 71 and instruction_words >= 4) {
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 11) {
                const builtin = read_u32_le(binary, (i + 3) * 4);
                if (builtin == spirv.Builtin.FragCoord) found_frag_coord = true;
                if (builtin == spirv.Builtin.Position) found_position = true;
            }
        }
        i += instruction_words;
    }

    try testing.expect(found_frag_coord);
    try testing.expect(!found_position);
}

test "spirv vertex: struct return with position and location" {
    const source =
        \\struct VsOut {
        \\    @builtin(position) clip_pos: vec4f,
        \\    @location(0) uv: vec2f,
        \\}
        \\
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
        \\    var out: VsOut;
        \\    return out;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Verify Vertex execution model and at least one OpDecorate for Location
    var found_vertex = false;
    var found_location = false;
    var found_builtin = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 15 and wc >= 3) { // OpEntryPoint
            const exec_model = read_u32_le(binary, (i + 1) * 4);
            if (exec_model == 0) found_vertex = true; // Vertex
        }
        if (op == 71 and wc >= 3) { // OpDecorate
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 30) found_location = true; // Location
            if (decoration == 11) found_builtin = true; // BuiltIn
        }
        i += wc;
    }
    try testing.expect(found_vertex);
    try testing.expect(found_location);
    try testing.expect(found_builtin);
}

test "spirv vertex: struct input parameter" {
    const source =
        \\struct VertIn {
        \\    @location(0) pos: vec4f,
        \\    @location(1) uv: vec2f,
        \\}
        \\struct VertOut {
        \\    @builtin(position) clip_pos: vec4f,
        \\    @location(0) uv: vec2f,
        \\}
        \\@vertex
        \\fn vs_main(in: VertIn) -> VertOut {
        \\    var out: VertOut;
        \\    out.clip_pos = in.pos;
        \\    out.uv = in.uv;
        \\    return out;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Count Location decorations: should have at least 3
    // (2 input locations + 1 output location)
    var location_count: u32 = 0;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 71 and wc >= 3) { // OpDecorate
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 30) location_count += 1; // Location
        }
        i += wc;
    }
    try testing.expect(location_count >= 3);
}

test "spirv fragment: struct return with MRT outputs" {
    const source =
        \\struct FragOut {
        \\    @location(0) color0: vec4f,
        \\    @location(1) color1: vec4f,
        \\}
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> FragOut {
        \\    var out: FragOut;
        \\    out.color0 = vec4f(uv, 0.0, 1.0);
        \\    out.color1 = vec4f(1.0, 0.0, 0.0, 1.0);
        \\    return out;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Verify Fragment execution model and OriginUpperLeft execution mode
    var found_fragment = false;
    var found_origin_upper_left = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 15 and wc >= 3) { // OpEntryPoint
            const exec_model = read_u32_le(binary, (i + 1) * 4);
            if (exec_model == 4) found_fragment = true;
        }
        if (op == 16 and wc >= 3) { // OpExecutionMode
            const mode = read_u32_le(binary, (i + 2) * 4);
            if (mode == 7) found_origin_upper_left = true;
        }
        i += wc;
    }
    try testing.expect(found_fragment);
    try testing.expect(found_origin_upper_left);
}

test "spirv fragment: frag_depth output with DepthReplacing" {
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
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Verify DepthReplacing execution mode (12)
    var found_depth_replacing = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 16 and wc >= 3) { // OpExecutionMode
            const mode = read_u32_le(binary, (i + 2) * 4);
            if (mode == 12) found_depth_replacing = true;
        }
        i += wc;
    }
    try testing.expect(found_depth_replacing);
}

test "spirv vertex: interpolation decorations on outputs" {
    const source =
        \\struct VsOut {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) @interpolate(flat) flat_val: f32,
        \\    @location(1) @interpolate(linear) linear_val: vec2f,
        \\}
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
        \\    var out: VsOut;
        \\    return out;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Verify Flat (14) and NoPerspective (13) decorations
    var found_flat = false;
    var found_noperspective = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 71 and wc >= 3) { // OpDecorate
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 14) found_flat = true;
            if (decoration == 13) found_noperspective = true;
        }
        i += wc;
    }
    try testing.expect(found_flat);
    try testing.expect(found_noperspective);
}

test "spirv vertex: centroid interpolation sampling decoration" {
    const source =
        \\struct VsOut {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) @interpolate(perspective, centroid) centroid_val: vec2f,
        \\    @location(1) @interpolate(linear, centroid) linear_centroid_val: f32,
        \\}
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
        \\    var out: VsOut;
        \\    return out;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Verify Centroid (16) and NoPerspective (13) decorations
    var centroid_count: u32 = 0;
    var found_noperspective = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 71 and wc >= 3) { // OpDecorate
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 16) centroid_count += 1; // Centroid
            if (decoration == 13) found_noperspective = true; // NoPerspective
        }
        i += wc;
    }
    // Both outputs have centroid sampling
    try testing.expect(centroid_count >= 2);
    // linear, centroid output has NoPerspective
    try testing.expect(found_noperspective);
}

test "spirv vertex: sample interpolation sampling decoration" {
    const source =
        \\struct VsOut {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) @interpolate(perspective, sample) sample_val: vec2f,
        \\}
        \\@vertex
        \\fn vs_main(@builtin(vertex_index) vid: u32) -> VsOut {
        \\    var out: VsOut;
        \\    return out;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Verify Sample (17) decoration and SampleRateShading capability (35)
    var found_sample_decoration = false;
    var found_sample_rate_cap = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 71 and wc >= 3) { // OpDecorate
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 17) found_sample_decoration = true; // Sample
        }
        if (op == 17 and wc >= 2) { // OpCapability
            const cap = read_u32_le(binary, (i + 1) * 4);
            if (cap == 35) found_sample_rate_cap = true; // SampleRateShading
        }
        i += wc;
    }
    try testing.expect(found_sample_decoration);
    try testing.expect(found_sample_rate_cap);
}

test "spirv fragment: inter-stage variables with multiple locations" {
    const source =
        \\struct FsIn {
        \\    @location(0) uv: vec2f,
        \\    @location(1) normal: vec3f,
        \\    @location(2) @interpolate(flat) flat_id: u32,
        \\    @location(3) color: vec4f,
        \\}
        \\@fragment
        \\fn fs_main(input: FsIn) -> @location(0) vec4f {
        \\    return input.color;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Verify at least 4 input + 1 output Location decorations
    var location_count: u32 = 0;
    var found_flat = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 71 and wc >= 3) { // OpDecorate
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 30) location_count += 1; // Location
            if (decoration == 14) found_flat = true; // Flat
        }
        i += wc;
    }
    try testing.expect(location_count >= 5);
    try testing.expect(found_flat);
}

test "spirv fragment: MRT struct output with three targets" {
    const source =
        \\struct MrtOut {
        \\    @location(0) albedo: vec4f,
        \\    @location(1) normal: vec4f,
        \\    @location(2) emission: vec4f,
        \\}
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> MrtOut {
        \\    var out: MrtOut;
        \\    out.albedo = vec4f(uv, 0.0, 1.0);
        \\    out.normal = vec4f(0.0, 0.0, 1.0, 0.0);
        \\    out.emission = vec4f(0.0);
        \\    return out;
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Count output Location decorations: at least 3 for MRT + 1 for input
    var location_count: u32 = 0;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 71 and wc >= 4) { // OpDecorate with operand
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 30) location_count += 1; // Location
        }
        i += wc;
    }
    try testing.expect(location_count >= 4);
}

test "spirv fragment: texture sampling with separate texture and sampler" {
    const source =
        \\@group(0) @binding(0) var t: texture_2d<f32>;
        \\@group(0) @binding(1) var s: sampler;
        \\
        \\@fragment
        \\fn main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        \\  return textureSample(t, s, uv);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    try testing.expect(len >= 20);
    try testing.expectEqual(spirv.MAGIC, read_u32_le(binary, 0));

    // Verify Fragment execution model (4), OriginUpperLeft mode (7),
    // DescriptorSet (34) and Binding (33) decorations for the texture/sampler,
    // and at least one Location decoration for I/O.
    var found_fragment = false;
    var found_origin = false;
    var found_descriptor_set = false;
    var found_binding = false;
    var found_location = false;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == 15 and wc >= 3) { // OpEntryPoint
            const exec_model = read_u32_le(binary, (i + 1) * 4);
            if (exec_model == 4) found_fragment = true;
        }
        if (op == 16 and wc >= 3) { // OpExecutionMode
            const mode = read_u32_le(binary, (i + 2) * 4);
            if (mode == 7) found_origin = true;
        }
        if (op == 71 and wc >= 4) { // OpDecorate
            const decoration = read_u32_le(binary, (i + 2) * 4);
            if (decoration == 34) found_descriptor_set = true; // DescriptorSet
            if (decoration == 33) found_binding = true; // Binding
            if (decoration == 30) found_location = true; // Location
        }
        i += wc;
    }
    try testing.expect(found_fragment);
    try testing.expect(found_origin);
    try testing.expect(found_descriptor_set);
    try testing.expect(found_binding);
    try testing.expect(found_location);
}

test "spirv graphics: entry interface excludes descriptor globals" {
    const source =
        \\struct Params { scale: f32 }
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\
        \\@fragment
        \\fn main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
        \\    return vec4<f32>(uv * params.scale, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const len = try translateToSpirv(allocator, source, &out);
    const binary = out[0..len];

    var uniform_vars: [16]u32 = undefined;
    var uniform_var_count: usize = 0;
    const word_count = len / 4;
    var i: usize = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == spirv.Opcode.Variable and wc >= 4 and read_u32_le(binary, (i + 3) * 4) == spirv.StorageClass.Uniform) {
            uniform_vars[uniform_var_count] = read_u32_le(binary, (i + 2) * 4);
            uniform_var_count += 1;
        }
        i += wc;
    }
    try testing.expect(uniform_var_count > 0);

    i = 5;
    while (i < word_count) {
        const w = read_u32_le(binary, i * 4);
        const op = w & 0xFFFF;
        const wc = w >> 16;
        if (op == spirv.Opcode.EntryPoint and wc >= 3 and read_u32_le(binary, (i + 1) * 4) == spirv.ExecutionModel.Fragment) {
            var operand_index: usize = i + 3;
            while (operand_index < i + wc) : (operand_index += 1) {
                const word = read_u32_le(binary, operand_index * 4);
                if ((word & 0xff) == 0 or ((word >> 8) & 0xff) == 0 or ((word >> 16) & 0xff) == 0 or ((word >> 24) & 0xff) == 0) {
                    operand_index += 1;
                    break;
                }
            }
            while (operand_index < i + wc) : (operand_index += 1) {
                const operand = read_u32_le(binary, operand_index * 4);
                for (uniform_vars[0..uniform_var_count]) |uniform_var| {
                    try testing.expect(operand != uniform_var);
                }
            }
        }
        i += wc;
    }
}
