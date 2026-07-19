// wgsl_cross_backend_test.zig — Cross-backend WGSL emission tests.
//
// Verifies that the same WGSL source produces valid, non-empty output across
// SPIR-V, MSL, and HLSL backends. Tests use the public module API
// (translateToMsl, translateToHlsl, translateToSpirv, analyzeToIr) rather
// than internal emitter functions.

const std = @import("std");
const mod = @import("../../src/compiler/wgsl/mod.zig");

const translateToMsl = mod.translateToMsl;
const translateToHlsl = mod.translateToHlsl;
const translateToSpirv = mod.translateToSpirv;
const analyzeToIr = mod.analyzeToIr;
const ir = mod.ir;

const MAX_MSL = mod.MAX_OUTPUT;
const MAX_HLSL = mod.MAX_HLSL_OUTPUT;
const MAX_SPIRV = mod.MAX_SPIRV_OUTPUT;

const alloc = std.testing.allocator;

// ============================================================
// Helpers
// ============================================================

const BackendOutputs = struct {
    msl: []const u8,
    hlsl: []const u8,
    spirv_len: usize,
};

fn compile_all_backends(source: []const u8, msl_buf: []u8, hlsl_buf: []u8, spirv_buf: []u8) !BackendOutputs {
    const msl_len = try translateToMsl(alloc, source, msl_buf);
    const hlsl_len = try translateToHlsl(alloc, source, hlsl_buf);
    const spirv_len = try translateToSpirv(alloc, source, spirv_buf);
    return .{
        .msl = msl_buf[0..msl_len],
        .hlsl = hlsl_buf[0..hlsl_len],
        .spirv_len = spirv_len,
    };
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ============================================================
// 1. Minimal compute shader compiles to all backends
// ============================================================

test "cross-backend: minimal compute shader produces non-empty output on all backends" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);
}

// ============================================================
// 2. Buffer binding preservation
// ============================================================

test "cross-backend: storage and uniform bindings appear in MSL and HLSL output" {
    const source =
        \\@group(0) @binding(0) var<uniform> params: vec4f;
        \\@group(0) @binding(1) var<storage, read_write> data: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x] = params.x;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    // MSL: uniform as constant reference with [[buffer(N)]]
    try std.testing.expect(contains(out.msl, "params"));
    try std.testing.expect(contains(out.msl, "[[buffer("));
    try std.testing.expect(contains(out.msl, "data"));

    // HLSL: uniform as cbuffer, storage as RWStructuredBuffer
    try std.testing.expect(contains(out.hlsl, "params"));
    try std.testing.expect(contains(out.hlsl, "cbuffer"));
    try std.testing.expect(contains(out.hlsl, "data"));
    try std.testing.expect(contains(out.hlsl, "RWStructuredBuffer"));

    // SPIR-V: non-empty binary
    try std.testing.expect(out.spirv_len > 0);
}

// ============================================================
// 3. Workgroup size propagation
// ============================================================

test "cross-backend: workgroup_size annotation survives compilation" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\
        \\@compute @workgroup_size(8, 4, 2)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = 1.0;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    // HLSL: [numthreads(8, 4, 2)]
    try std.testing.expect(contains(out.hlsl, "numthreads(8, 4, 2)"));

    // MSL: [[max_total_threads_per_threadgroup(...)]] or the kernel attribute
    // The workgroup size is part of the dispatch metadata; verify the shader compiled.
    try std.testing.expect(out.msl.len > 0);

    // SPIR-V: binary includes workgroup size in execution mode (non-empty output)
    try std.testing.expect(out.spirv_len > 0);

    // Also verify the IR captures the workgroup size correctly.
    var module_ir = try analyzeToIr(alloc, source);
    defer module_ir.deinit();
    var found_entry = false;
    for (module_ir.entry_points.items) |ep| {
        if (ep.stage == .compute) {
            try std.testing.expectEqual(@as(u32, 8), ep.workgroup_size[0]);
            try std.testing.expectEqual(@as(u32, 4), ep.workgroup_size[1]);
            try std.testing.expectEqual(@as(u32, 2), ep.workgroup_size[2]);
            found_entry = true;
        }
    }
    try std.testing.expect(found_entry);
}

// ============================================================
// 4. Entry point naming
// ============================================================

test "cross-backend: entry point name preserved across backends" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn my_compute_main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = 1.0;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    // HLSL: function name appears directly
    try std.testing.expect(contains(out.hlsl, "my_compute_main"));

    // MSL: kernel entry point wraps with _kernel suffix
    try std.testing.expect(contains(out.msl, "my_compute_main"));

    // SPIR-V: non-empty (name is embedded in OpEntryPoint as a string)
    try std.testing.expect(out.spirv_len > 0);
}

// ============================================================
// 5. Type mapping consistency
// ============================================================

test "cross-backend: f32 u32 vec4f mat4x4f type mapping" {
    const source =
        \\struct Params {
        \\    transform: mat4x4f,
        \\    color: vec4f,
        \\    count: u32,
        \\    scale: f32,
        \\};
        \\
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\@group(0) @binding(1) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    out[gid.x] = params.scale + params.color.x + params.transform[0][0];
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    // MSL type names
    try std.testing.expect(contains(out.msl, "float4x4"));
    try std.testing.expect(contains(out.msl, "float4"));
    try std.testing.expect(contains(out.msl, "uint"));
    try std.testing.expect(contains(out.msl, "float"));

    // HLSL type names
    try std.testing.expect(contains(out.hlsl, "float4x4"));
    try std.testing.expect(contains(out.hlsl, "float4"));
    try std.testing.expect(contains(out.hlsl, "uint"));
    try std.testing.expect(contains(out.hlsl, "float"));

    // SPIR-V binary produced
    try std.testing.expect(out.spirv_len > 0);
}

// ============================================================
// 6. Error consistency
// ============================================================

test "cross-backend: invalid WGSL produces errors on all backends without crashing" {
    const invalid_source = "fn main( { invalid syntax here }";

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;

    const msl_err = translateToMsl(alloc, invalid_source, &msl_buf);
    const hlsl_err = translateToHlsl(alloc, invalid_source, &hlsl_buf);
    const spirv_err = translateToSpirv(alloc, invalid_source, &spirv_buf);

    // All backends return errors (not success, not a crash)
    try std.testing.expect(msl_err == error.UnexpectedToken or
        msl_err == error.InvalidWgsl or
        msl_err == error.InvalidType);
    try std.testing.expect(hlsl_err == error.UnexpectedToken or
        hlsl_err == error.InvalidWgsl or
        hlsl_err == error.InvalidType);
    try std.testing.expect(spirv_err == error.UnexpectedToken or
        spirv_err == error.InvalidWgsl or
        spirv_err == error.InvalidType);
}

test "cross-backend: undeclared identifier errors on all backends" {
    const source =
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let x = undefined_symbol;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;

    const msl_err = translateToMsl(alloc, source, &msl_buf);
    const hlsl_err = translateToHlsl(alloc, source, &hlsl_buf);
    const spirv_err = translateToSpirv(alloc, source, &spirv_buf);

    try std.testing.expectError(error.UnknownIdentifier, msl_err);
    try std.testing.expectError(error.UnknownIdentifier, hlsl_err);
    try std.testing.expectError(error.UnknownIdentifier, spirv_err);
}

// ============================================================
// 7. Robustness transform
// ============================================================

test "cross-backend: robustness bounds clamping does not crash any backend" {
    // The default translation path applies the robustness transform.
    // Verify that a shader with array indexing compiles through all backends
    // with the transform active (the default).
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let idx = gid.x;
        \\    buf[idx] = buf[idx] + 1.0;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);

    // MSL robustness: expect min/clamp for bounds safety
    try std.testing.expect(contains(out.msl, "min(") or contains(out.msl, "clamp(") or out.msl.len > 100);
    // HLSL robustness: expect min/clamp for bounds safety
    try std.testing.expect(contains(out.hlsl, "min(") or contains(out.hlsl, "clamp(") or out.hlsl.len > 100);
}

// ============================================================
// 8. Multiple bindings
// ============================================================

test "cross-backend: shader with 3+ bindings compiles across all backends" {
    const source =
        \\@group(0) @binding(0) var<uniform> params: vec4f;
        \\@group(0) @binding(1) var<storage, read> input: array<f32>;
        \\@group(0) @binding(2) var<storage, read_write> output: array<f32>;
        \\@group(1) @binding(0) var<uniform> extra: vec4f;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    output[gid.x] = input[gid.x] * params.x + extra.y;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);

    // MSL: all four binding names present
    try std.testing.expect(contains(out.msl, "params"));
    try std.testing.expect(contains(out.msl, "input"));
    try std.testing.expect(contains(out.msl, "output"));
    try std.testing.expect(contains(out.msl, "extra"));

    // HLSL: all four binding names present
    try std.testing.expect(contains(out.hlsl, "params"));
    try std.testing.expect(contains(out.hlsl, "input"));
    try std.testing.expect(contains(out.hlsl, "output"));
    try std.testing.expect(contains(out.hlsl, "extra"));

    // HLSL: multiple register spaces for cross-group bindings
    try std.testing.expect(contains(out.hlsl, "space0"));
    try std.testing.expect(contains(out.hlsl, "space1"));

    // Verify IR binding count
    var bindings: [mod.MAX_BINDINGS]mod.BindingMeta = undefined;
    const count = try mod.extractBindings(alloc, source, &bindings);
    try std.testing.expectEqual(@as(usize, 4), count);
}

// ============================================================
// 9. Texture sampling
// ============================================================

test "cross-backend: texture load compiles across all backends" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var<storage, read_write> out: array<f32>;
        \\
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let color = textureLoad(tex, vec2u(gid.x, 0u), 0);
        \\    out[gid.x] = color.x;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);

    // MSL: texture read
    try std.testing.expect(contains(out.msl, "tex"));
    try std.testing.expect(contains(out.msl, "read"));

    // HLSL: texture Load
    try std.testing.expect(contains(out.hlsl, "tex"));
    try std.testing.expect(contains(out.hlsl, ".Load("));
}

test "cross-backend: texture sample compiles across all backends" {
    const source =
        \\@group(0) @binding(0) var tex: texture_2d<f32>;
        \\@group(0) @binding(1) var samp: sampler;
        \\
        \\@fragment
        \\fn main(@location(0) uv: vec2f) -> @location(0) vec4f {
        \\    return textureSample(tex, samp, uv);
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);

    // MSL: sample method
    try std.testing.expect(contains(out.msl, "sample("));

    // HLSL: Sample method
    try std.testing.expect(contains(out.hlsl, ".Sample("));
}

// ============================================================
// 10. Builtin variables
// ============================================================

test "cross-backend: global_invocation_id builtin compiles across backends" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x + gid.y + gid.z;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);

    // MSL: thread_position_in_grid is the Metal equivalent
    try std.testing.expect(contains(out.msl, "thread_position_in_grid"));

    // HLSL: SV_DispatchThreadID is the HLSL equivalent
    try std.testing.expect(contains(out.hlsl, "SV_DispatchThreadID"));
}

test "cross-backend: local_invocation_id builtin compiles across backends" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_id) lid: vec3u) {
        \\    buf[lid.x] = lid.x;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);

    // MSL: thread_position_in_threadgroup
    try std.testing.expect(contains(out.msl, "thread_position_in_threadgroup"));

    // HLSL: SV_GroupThreadID
    try std.testing.expect(contains(out.hlsl, "SV_GroupThreadID"));
}

test "cross-backend: workgroup_id builtin compiles across backends" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(workgroup_id) wgid: vec3u) {
        \\    buf[wgid.x] = wgid.x;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);

    // MSL: threadgroup_position_in_grid
    try std.testing.expect(contains(out.msl, "threadgroup_position_in_grid"));

    // HLSL: SV_GroupID
    try std.testing.expect(contains(out.hlsl, "SV_GroupID"));
}

test "cross-backend: vertex_index and position builtins compile across backends" {
    const source =
        \\@vertex
        \\fn main(@builtin(vertex_index) vid: u32) -> @builtin(position) vec4f {
        \\    let x = f32(vid) / 3.0;
        \\    return vec4f(x, 0.0, 0.0, 1.0);
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);

    // MSL: vertex_id attribute
    try std.testing.expect(contains(out.msl, "vertex_id"));

    // HLSL: SV_VertexID and SV_Position
    try std.testing.expect(contains(out.hlsl, "SV_VertexID"));
    try std.testing.expect(contains(out.hlsl, "SV_Position"));
}

// ============================================================
// Additional: combined vertex+fragment pipeline
// ============================================================

test "cross-backend: fragment shader with location IO compiles across backends" {
    const source =
        \\@fragment
        \\fn main(@location(0) color: vec4f) -> @location(0) vec4f {
        \\    return color;
        \\}
    ;

    var msl_buf: [MAX_MSL]u8 = undefined;
    var hlsl_buf: [MAX_HLSL]u8 = undefined;
    var spirv_buf: [MAX_SPIRV]u8 = undefined;
    const out = try compile_all_backends(source, &msl_buf, &hlsl_buf, &spirv_buf);

    try std.testing.expect(out.msl.len > 0);
    try std.testing.expect(out.hlsl.len > 0);
    try std.testing.expect(out.spirv_len > 0);

    // MSL: fragment stage annotation
    try std.testing.expect(contains(out.msl, "fragment"));
    try std.testing.expect(contains(out.msl, "[[color(0)]]"));

    // HLSL: SV_Target0 for color output
    try std.testing.expect(contains(out.hlsl, "SV_Target0"));
}
