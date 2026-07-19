// msl_subsystem_test.zig — MSL subsystem tests for the Doe WGSL-to-MSL pipeline.
//
// Verifies MSL output correctness across the emit_msl* modules:
//   emit_msl.zig, emit_msl_ir.zig, emit_msl_shared.zig,
//   emit_msl_stage.zig, emit_msl_texture.zig, emit_msl_vertex.zig
//
// Tests use the public translateToMsl API to compile WGSL to MSL,
// then verify output contains expected Metal constructs.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");

const translateToMsl = mod.translateToMsl;
const MAX_OUTPUT = mod.MAX_OUTPUT;
const alloc = std.testing.allocator;

// ============================================================
// Helpers
// ============================================================

fn compile_msl(source: []const u8) ![]const u8 {
    const buf = try alloc.alloc(u8, MAX_OUTPUT);
    errdefer alloc.free(buf);
    const len = try translateToMsl(alloc, source, buf);
    return buf[0..len];
}

fn free_msl(msl: []const u8) void {
    const full_buf: []u8 = @constCast(msl.ptr[0..MAX_OUTPUT]);
    alloc.free(full_buf);
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn expectHas(msl: []const u8, needle: []const u8) !void {
    if (!has(msl, needle)) {
        std.debug.print("\n--- MSL output ---\n{s}\n--- end ---\nExpected: \"{s}\"\n", .{ msl, needle });
        return error.TestExpectedEqual;
    }
}

// ============================================================
// 1. MSL preamble
// ============================================================

test "msl: preamble includes metal_stdlib" {
    const msl = try compile_msl(
        \\@compute @workgroup_size(1)
        \\fn main() {}
    );
    defer free_msl(msl);
    try expectHas(msl, "#include <metal_stdlib>");
    try expectHas(msl, "using namespace metal;");
}

// ============================================================
// 2. Type mapping: scalars, vectors, matrices, arrays
// ============================================================

test "msl: scalar type mapping — f32/u32/i32" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<storage, read_write> bf: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> bu: array<u32>;
        \\@group(0) @binding(2) var<storage, read_write> bi: array<i32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    bf[gid.x] = 1.0; bu[gid.x] = 1u; bi[gid.x] = 1;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "float*");
    try expectHas(msl, "uint*");
    try expectHas(msl, "int*");
}

test "msl: vector type mapping — float4, uint3" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<uniform> v: vec4f;
        \\@group(0) @binding(1) var<storage, read_write> out: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    out[gid.x] = u32(v.x);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "float4");
    try expectHas(msl, "uint3");
}

test "msl: matrix type mapping — float4x4" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<uniform> m: mat4x4f;
        \\@group(0) @binding(1) var<storage, read_write> out: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    out[gid.x] = m[0][0];
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "float4x4");
}

test "msl: fixed-size local array emits C-style declaration" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    var a: array<f32, 4>;
        \\    a[0] = 1.0;
        \\    buf[0] = u32(a[0]);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "float a[4];");
}

// ============================================================
// 3. Address space mapping (MslAddressSpace.lean proves these)
// ============================================================

test "msl: uniform maps to constant&, storage rw to device, storage r to const device" {
    const msl = try compile_msl(
        \\struct P { scale: f32 }
        \\@group(0) @binding(0) var<uniform> params: P;
        \\@group(0) @binding(1) var<storage, read> inp: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> out: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    out[gid.x] = inp[gid.x] + params.scale;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "constant P&");
    try expectHas(msl, "const device float*");
    try expectHas(msl, "device float*");
}

test "msl: workgroup maps to threadgroup" {
    const msl = try compile_msl(
        \\var<workgroup> shared_data: array<f32, 64>;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_index) lid: u32) {
        \\    shared_data[lid] = f32(lid);
        \\    workgroupBarrier();
        \\    buf[lid] = shared_data[lid];
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "threadgroup ");
}

// ============================================================
// 4. Buffer binding — [[buffer(N)]]
// ============================================================

test "msl: buffer binding indices [[buffer(N)]]" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<uniform> a: vec4f;
        \\@group(0) @binding(1) var<storage, read_write> b: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    b[gid.x] = a.x;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "[[buffer(0)]]");
    try expectHas(msl, "[[buffer(1)]]");
}

test "msl: multi-group slot calculation (group*16+binding)" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<storage, read_write> b0: array<u32>;
        \\@group(1) @binding(2) var<uniform> params: vec4f;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    b0[gid.x] = u32(params.x);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "[[buffer(0)]]");
    try expectHas(msl, "[[buffer(18)]]");
}

// ============================================================
// 5. Texture and sampler binding
// ============================================================

test "msl: texture2d and sampler bindings with [[texture(N)]] [[sampler(N)]]" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    return textureSample(tex, samp, uv);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "texture2d<float>");
    try expectHas(msl, "[[texture(0)]]");
    try expectHas(msl, "sampler ");
    try expectHas(msl, "[[sampler(1)]]");
}

test "msl: storage texture 2d with access::write" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var t: texture_storage_2d<rgba8unorm, write>;
        \\@compute @workgroup_size(8, 8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    textureStore(t, vec2u(gid.xy), vec4f(1.0, 0.0, 0.0, 1.0));
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "texture2d<float, access::write>");
    try expectHas(msl, "[[texture(0)]]");
}

test "msl: depth texture maps to depth2d<float>" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_depth_2d;
        \\@group(0) @binding(1) var samp: sampler_comparison;
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) f32 {
        \\    return textureSampleCompare(tex, samp, uv, 0.5);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "depth2d<float>");
}

// ============================================================
// 6. Compute kernel — [[kernel]], builtin mapping
// ============================================================

test "msl: compute emits [[kernel]] and main_kernel" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "[[kernel]]");
    try expectHas(msl, "main_kernel");
}

test "msl: compute builtins map to Metal attributes" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u,
        \\        @builtin(local_invocation_id) lid: vec3u) {
        \\    buf[gid.x] = lid.x;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "thread_position_in_grid");
    try expectHas(msl, "thread_position_in_threadgroup");
}

test "msl: barriers map to threadgroup_barrier variants" {
    const msl = try compile_msl(
        \\var<workgroup> s: array<u32, 64>;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_index) lid: u32) {
        \\    s[lid] = lid;
        \\    workgroupBarrier();
        \\    storageBarrier();
        \\    buf[lid] = s[lid];
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "threadgroup_barrier(mem_flags::mem_threadgroup)");
    try expectHas(msl, "threadgroup_barrier(mem_flags::mem_device)");
}

// ============================================================
// 7. Vertex shader — [[position]], [[user(locN)]], vertex_id
// ============================================================

test "msl: vertex emits vertex qualifier and [[position]]" {
    const msl = try compile_msl(
        \\struct VO { @builtin(position) pos: vec4f, @location(0) uv: vec2f }
        \\@vertex
        \\fn main(@builtin(vertex_index) vid: u32) -> VO {
        \\    var out: VO;
        \\    out.pos = vec4f(0.0, 0.0, 0.0, 1.0);
        \\    out.uv = vec2f(0.0, 0.0);
        \\    return out;
        \\}
    );
    defer free_msl(msl);
    const has_vertex = has(msl, "[[vertex]]") or has(msl, "vertex ");
    try std.testing.expect(has_vertex);
    try expectHas(msl, "[[position]]");
}

test "msl: vertex output locations map to [[user(locN)]]" {
    const msl = try compile_msl(
        \\struct VO {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) color: vec4f,
        \\    @location(1) uv: vec2f,
        \\}
        \\@vertex
        \\fn main(@builtin(vertex_index) vid: u32) -> VO {
        \\    var out: VO;
        \\    out.pos = vec4f(0.0, 0.0, 0.0, 1.0);
        \\    out.color = vec4f(1.0, 0.0, 0.0, 1.0);
        \\    out.uv = vec2f(0.0, 0.0);
        \\    return out;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "[[user(loc0)]]");
    try expectHas(msl, "[[user(loc1)]]");
}

test "msl: vertex_index and instance_index map to vertex_id/instance_id" {
    const msl = try compile_msl(
        \\struct VO { @builtin(position) pos: vec4f }
        \\@vertex
        \\fn main(@builtin(vertex_index) vid: u32, @builtin(instance_index) iid: u32) -> VO {
        \\    var out: VO;
        \\    out.pos = vec4f(f32(vid + iid), 0.0, 0.0, 1.0);
        \\    return out;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "vertex_id");
    try expectHas(msl, "instance_id");
}

test "msl: vertex with uniform buffer uses [[buffer(N)]]" {
    const msl = try compile_msl(
        \\struct U { scale: f32 }
        \\@group(0) @binding(0) var<uniform> u: U;
        \\struct VO { @builtin(position) pos: vec4f }
        \\@vertex
        \\fn main(@builtin(vertex_index) vid: u32) -> VO {
        \\    var out: VO;
        \\    out.pos = vec4f(u.scale, 0.0, 0.0, 1.0);
        \\    return out;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "[[buffer(0)]]");
    try expectHas(msl, "constant U&");
}

// ============================================================
// 8. Fragment shader — [[color(N)]], discard_fragment
// ============================================================

test "msl: fragment emits fragment qualifier and [[color(N)]]" {
    const msl = try compile_msl(
        \\struct FO { @location(0) c0: vec4f, @location(1) c1: vec4f }
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> FO {
        \\    var out: FO;
        \\    out.c0 = vec4f(uv, 0.0, 1.0);
        \\    out.c1 = vec4f(0.0, uv.x, uv.y, 1.0);
        \\    return out;
        \\}
    );
    defer free_msl(msl);
    const has_frag = has(msl, "[[fragment]]") or has(msl, "fragment ");
    try std.testing.expect(has_frag);
    try expectHas(msl, "[[color(0)]]");
    try expectHas(msl, "[[color(1)]]");
}

test "msl: single-location fragment return emits color(0)" {
    const msl = try compile_msl(
        \\@fragment
        \\fn main() -> @location(0) vec4f {
        \\    return vec4f(1.0, 0.0, 0.0, 1.0);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "color(0)");
}

test "msl: discard maps to discard_fragment()" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    let c = textureSample(tex, samp, uv);
        \\    if (c.a < 0.5) { discard; }
        \\    return c;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "discard_fragment()");
}

// ============================================================
// 9. Texture operations — .sample(), .read(), .write()
// ============================================================

test "msl: textureSample maps to .sample()" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    return textureSample(tex, samp, uv);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, ".sample(");
}

test "msl: external texture base-clamp sample maps to .sample()" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var samp: sampler;
        \\@group(0) @binding(1) var tex: texture_external;
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    return textureSampleBaseClampToEdge(tex, samp, uv);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "tex.sample(samp, uv)");
}

test "msl: textureLoad maps to .read()" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@fragment
        \\fn main(@builtin(position) pos: vec4f) -> @location(0) vec4f {
        \\    return textureLoad(tex, vec2u(u32(pos.x), u32(pos.y)), 0);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, ".read(");
}

test "msl: textureStore maps to .write()" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_storage_2d<rgba8unorm, write>;
        \\@compute @workgroup_size(8, 8)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    textureStore(tex, vec2u(gid.xy), vec4f(1.0, 0.0, 0.0, 1.0));
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, ".write(");
}

test "msl: textureSampleLevel emits level()" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    return textureSampleLevel(tex, samp, uv, 0.0);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, ".sample(");
    try expectHas(msl, "level(");
}

test "msl: textureSampleCompare maps to .sample_compare()" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_depth_2d;
        \\@group(0) @binding(1) var samp: sampler_comparison;
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) f32 {
        \\    return textureSampleCompare(tex, samp, uv, 0.5);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, ".sample_compare(");
}

test "msl: textureDimensions emits get_width/get_height" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let dims = textureDimensions(tex, 0);
        \\    out[0] = dims.x;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "get_width(");
    try expectHas(msl, "get_height(");
}

// ============================================================
// 10. Struct emission
// ============================================================

test "msl: user-defined struct with typed fields" {
    const msl = try compile_msl(
        \\struct Params { offset: vec4f, scale: f32 }
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\@group(0) @binding(1) var<storage, read_write> out: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    out[gid.x] = params.scale + params.offset.x;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "struct Params");
    try expectHas(msl, "float4 offset");
    try expectHas(msl, "float scale");
}

// ============================================================
// 11. Atomic types and operations
// ============================================================

test "msl: atomic u32 maps to atomic_uint with fetch_add" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<storage, read_write> counter: atomic<u32>;
        \\@compute @workgroup_size(64)
        \\fn main() { atomicAdd(&counter, 1u); }
    );
    defer free_msl(msl);
    try expectHas(msl, "atomic_uint");
    try expectHas(msl, "atomic_fetch_add_explicit");
    try expectHas(msl, "memory_order_relaxed");
}

// ============================================================
// 12. Builtin function mapping
// ============================================================

test "msl: inverseSqrt maps to rsqrt" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = inverseSqrt(buf[gid.x]);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "rsqrt(");
}

test "msl: select maps to ternary" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = select(0.0, 1.0, buf[gid.x] > 0.5);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "?");
    try expectHas(msl, ":");
}

// ============================================================
// 13. Output buffer overflow
// ============================================================

test "msl: OutputTooLarge on tiny buffer" {
    var tiny: [8]u8 = undefined;
    const result = translateToMsl(alloc,
        \\@compute @workgroup_size(1)
        \\fn main() {}
    , &tiny);
    try std.testing.expectError(error.OutputTooLarge, result);
}

// ============================================================
// 14. Full pipeline: fragment with texture + sampler + color
// ============================================================

test "msl: full fragment pipeline with texture, sampler, color output" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\struct FO { @location(0) color: vec4f }
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> FO {
        \\    var out: FO;
        \\    out.color = textureSample(tex, samp, uv);
        \\    return out;
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "texture2d<float>");
    try expectHas(msl, "[[texture(0)]]");
    try expectHas(msl, "[[sampler(1)]]");
    try expectHas(msl, "[[color(0)]]");
    try expectHas(msl, ".sample(");
}

test "msl: stage wrapper generated names do not collide with WGSL parameters" {
    const msl = try compile_msl(
        \\struct VsOut {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) uv: vec2f,
        \\}
        \\@vertex
        \\fn vs(@builtin(vertex_index) index: u32) -> VsOut {
        \\    var out: VsOut;
        \\    out.pos = vec4f(0.0, 0.0, 0.0, 1.0);
        \\    out.uv = vec2f(0.5, 0.5);
        \\    return out;
        \\}
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\@fragment
        \\fn fs(in: VsOut) -> @location(0) vec4f {
        \\    return textureSample(tex, samp, in.uv);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "fs_stage_in _doe_stage_input [[stage_in]]");
    try expectHas(msl, "VsOut in;");
    try expectHas(msl, "in.pos = _doe_stage_input.p0;");
    try expectHas(msl, "in.uv = _doe_stage_input.p1;");
    try std.testing.expect(!has(msl, "fs_stage_in in [[stage_in]]"));
}

// ============================================================
// 15. Boolean literal emission
// ============================================================

test "msl: boolean true emits correctly" {
    const msl = try compile_msl(
        \\@group(0) @binding(0) var<storage, read_write> out: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let cond = true;
        \\    if (cond) { out[0] = 1u; }
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "true");
}

// ============================================================
// 16. f16 type mapping
// ============================================================

test "msl: f16 maps to half" {
    const msl = try compile_msl(
        \\enable f16;
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let h: f16 = f16(buf[gid.x]);
        \\    buf[gid.x] = f32(h);
        \\}
    );
    defer free_msl(msl);
    try expectHas(msl, "half");
}
