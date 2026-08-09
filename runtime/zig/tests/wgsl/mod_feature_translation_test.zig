// mod_feature_translation_test.zig — Cross-backend builtin, texture, and stage feature translation tests.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const translateToMsl = mod.translateToMsl;
const translateToHlsl = mod.translateToHlsl;
const translateToSpirv = mod.translateToSpirv;
const MAX_OUTPUT = mod.MAX_OUTPUT;
const MAX_HLSL_OUTPUT = mod.MAX_HLSL_OUTPUT;
const MAX_SPIRV_OUTPUT = mod.MAX_SPIRV_OUTPUT;

test "translate explicit numeric and bool scalar conversions" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let enabled = bool(data[0]);
        \\    let integer = u32(!enabled);
        \\    let signed = i32(enabled);
        \\    let decimal = f32(enabled);
        \\    data[0] = integer + u32(signed) + u32(decimal);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    try std.testing.expect(try translateToMsl(std.testing.allocator, source, &msl_out) > 0);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    try std.testing.expect(try translateToHlsl(std.testing.allocator, source, &hlsl_out) > 0);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    try std.testing.expect(try translateToSpirv(std.testing.allocator, source, &spirv_out) > 0);
}

test "translate workgroupBarrier builtin to MSL SPIR-V and HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 1.0;
        \\    workgroupBarrier();
        \\    data[id.x] = data[id.x] + 1.0;
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "threadgroup_barrier(mem_flags::mem_threadgroup)") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "GroupMemoryBarrierWithGroupSync()") != null);
}

test "translate storageBarrier builtin to MSL SPIR-V and HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = 1.0;
        \\    storageBarrier();
        \\    data[id.x] = data[id.x] + 1.0;
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "threadgroup_barrier(mem_flags::mem_device)") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "AllMemoryBarrierWithGroupSync()") != null);
}

test "translate fma builtin to MSL SPIR-V and HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let a = data[id.x];
        \\    let b = data[id.x + 1u];
        \\    let c = data[id.x + 2u];
        \\    data[id.x] = fma(a, b, c);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "fma(") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "fma(") != null);
}

test "translate smoothstep builtin to MSL SPIR-V and HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    data[id.x] = smoothstep(0.0, 1.0, data[id.x]);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "smoothstep(") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "smoothstep(") != null);
}

test "ptr parameter codegen is supported" {
    const source =
        \\fn helper(p: ptr<function, f32>) {
        \\    // Pointer parameter is accepted and carried through codegen.
        \\}
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    var x: f32 = 0.0;
        \\    helper(&x);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "thread float& p") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "helper(x)") != null);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "helper(") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "float p") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "texture_3d type compiles to MSL" {
    const source =
        \\@group(0) @binding(0) var tex: texture_3d<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "translate textureSample builtin to MSL HLSL and SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureSample(tex, samp, uv).x;
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], ".sample(") != null);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], ".Sample(") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "translate textureSampleLevel builtin to MSL HLSL and SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureSampleLevel(tex, samp, uv, 0.0).x;
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], ".sample(") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "level(") != null);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], ".SampleLevel(") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "translate textureSample builtin through aliases to HLSL" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let tex_alias = tex;
        \\    let samp_alias = samp;
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureSample(tex_alias, samp_alias, uv).x;
        \\}
    ;

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], ".Sample(") != null);
}

test "translate textureSampleLevel builtin through aliases to HLSL" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@group(0) @binding(2) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let tex_alias = tex;
        \\    let samp_alias = samp;
        \\    let uv = vec2f(0.5, 0.5);
        \\    out_data[id.x] = textureSampleLevel(tex_alias, samp_alias, uv, 0.0).x;
        \\}
    ;

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], ".SampleLevel(") != null);
}

test "translate textureDimensions builtin to MSL HLSL and SPIR-V" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var out_data: texture_storage_2d<rgba8unorm, write>;
        \\@group(0) @binding(2) var<storage, read_write> dims: array<u32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let sampled_dims = textureDimensions(tex, 0);
        \\    let storage_dims = textureDimensions(out_data);
        \\    dims[id.x] = sampled_dims.x + sampled_dims.y + storage_dims.x + storage_dims.y;
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], ".get_width(uint(") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], ".get_height()") != null);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "doe_textureDimensions_tex(uint(0))") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "doe_textureDimensions_out_data()") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "translate readonly storage texture through MSL HLSL and SPIR-V" {
    const source =
        \\@group(0) @binding(0) var input_tex: texture_storage_2d<rgba8unorm, read>;
        \\@group(0) @binding(1) var<storage, read_write> out_data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    out_data[id.x] = textureLoad(input_tex, vec2i(0, 0)).x;
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(
        std.mem.indexOf(u8, msl_out[0..msl_len], "access::read") != null,
    );

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(
        std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "Texture2D<float4> input_tex") != null,
    );

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "translate readwrite storage texture through MSL HLSL and SPIR-V" {
    const source =
        \\@group(0) @binding(0) var image: texture_storage_2d<rgba8unorm, read_write>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) id: vec3u) {
        \\    let value = textureLoad(image, vec2i(0, 0));
        \\    textureStore(image, vec2i(0, 0), value);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(
        std.mem.indexOf(u8, msl_out[0..msl_len], "access::read_write") != null,
    );

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(
        std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "RWTexture2D<float4> image") != null,
    );

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "translate subgroup_size and subgroup_invocation_id builtins to HLSL" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(32)
        \\fn main(@builtin(subgroup_size) sg_size: u32, @builtin(subgroup_invocation_id) sg_id: u32) {
        \\    data[sg_id] = f32(sg_size);
        \\}
    ;

    var out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const len = try translateToHlsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const hlsl = out[0..len];
    // Subgroup builtins should map to HLSL intrinsic calls, not parameter semantics
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "WaveGetLaneCount()") != null);
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "WaveGetLaneIndex()") != null);
    // They should NOT appear as entry-point parameter semantics
    try std.testing.expect(std.mem.indexOf(u8, hlsl, "UNSUPPORTED_BUILTIN") == null);
}

test "texture_depth_2d type compiles to MSL" {
    const source =
        \\@group(0) @binding(0) var depth: texture_depth_2d;
        \\
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\}
    ;

    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
}

test "clip_distances vertex shader builtin to MSL HLSL and SPIR-V" {
    const source =
        \\@vertex
        \\fn main(@builtin(vertex_index) vi: u32) -> @builtin(clip_distances) array<f32, 4> {
        \\    var distances: array<f32, 4>;
        \\    distances[0] = 1.0;
        \\    distances[1] = 2.0;
        \\    distances[2] = 3.0;
        \\    distances[3] = 4.0;
        \\    return distances;
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "clip_distance") != null);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "SV_ClipDistance") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "primitive_index fragment shader builtin to MSL HLSL and SPIR-V" {
    const source =
        \\@fragment
        \\fn main(@builtin(primitive_index) prim_id: u32) -> @location(0) vec4f {
        \\    return vec4f(f32(prim_id), 0.0, 0.0, 1.0);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "primitive_id") != null);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, hlsl_out[0..hlsl_len], "SV_PrimitiveID") != null);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}

test "dual_source_blending fragment output with blend_src to MSL HLSL and SPIR-V" {
    const source =
        \\@fragment
        \\fn main() -> @location(0) @blend_src(0) vec4f {
        \\    return vec4f(1.0, 0.0, 0.0, 1.0);
        \\}
    ;

    var msl_out: [MAX_OUTPUT]u8 = undefined;
    const msl_len = try translateToMsl(std.testing.allocator, source, &msl_out);
    try std.testing.expect(msl_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msl_out[0..msl_len], "color(0), index(0)") != null);

    var hlsl_out: [MAX_HLSL_OUTPUT]u8 = undefined;
    const hlsl_len = try translateToHlsl(std.testing.allocator, source, &hlsl_out);
    try std.testing.expect(hlsl_len > 0);

    var spirv_out: [MAX_SPIRV_OUTPUT]u8 = undefined;
    const spirv_len = try translateToSpirv(std.testing.allocator, source, &spirv_out);
    try std.testing.expect(spirv_len > 0);
}
