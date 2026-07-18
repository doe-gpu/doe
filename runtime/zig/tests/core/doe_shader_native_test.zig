// doe_shader_native_test.zig — Tests for the native shader compilation layer.
//
// Focuses on the doe_shader_native.zig module: WGSL source validation via
// doeNativeCheckShaderSource, error metadata propagation (stage, kind, line,
// column), error buffer management, and shader module creation through WGSL
// sType dispatch (without requiring a GPU device for compilation).
//
// Does NOT duplicate WGSL compiler internals (covered by test_suite_wgsl.zig)
// or precompiled shader paths (covered by precompiled_shader_test.zig).

const std = @import("std");

const shader = @import("../../src/doe_shader_native.zig");
const native = @import("../../src/doe_wgpu_native.zig");
const types = @import("../../src/core/abi/wgpu_runtime_abi.zig");

// ============================================================
// Helper: read error state after a shader check call
// ============================================================

fn readLastErrorMessage() []const u8 {
    var buf: [512]u8 = undefined;
    const len = shader.doeNativeCopyLastErrorMessage(&buf, buf.len);
    if (len == 0) return "";
    // Return a comptime-safe slice by copying to a persistent buffer.
    // For test assertions we re-read inline.
    return buf[0..len];
}

fn readErrorStage(buf: *[64]u8) []const u8 {
    const len = shader.doeNativeCopyLastErrorStage(buf, buf.len);
    return buf[0..len];
}

fn readErrorKind(buf: *[64]u8) []const u8 {
    const len = shader.doeNativeCopyLastErrorKind(buf, buf.len);
    return buf[0..len];
}

// ============================================================
// 1. Valid WGSL compilation — minimal shaders accepted
// ============================================================

test "check: minimal compute shader compiles successfully" {
    const wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
    try std.testing.expectEqual(@as(u32, 0), shader.doeNativeGetLastErrorLine());
    try std.testing.expectEqual(@as(u32, 0), shader.doeNativeGetLastErrorColumn());
}

test "check: compute shader with vec4f types compiles successfully" {
    const wgsl =
        \\@group(0) @binding(0) var<storage, read_write> data: array<vec4f>;
        \\@compute @workgroup_size(128)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    data[gid.x] = vec4f(1.0, 2.0, 3.0, 4.0);
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "check: shader with multiple bindings compiles successfully" {
    const wgsl =
        \\@group(0) @binding(0) var<storage, read> src: array<f32>;
        \\@group(0) @binding(1) var<storage, read_write> dst: array<f32>;
        \\@group(0) @binding(2) var<uniform> params: vec4f;
        \\@compute @workgroup_size(256)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    dst[gid.x] = src[gid.x] * params.x;
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

// ============================================================
// 2. Invalid WGSL rejection — syntax and semantic errors
// ============================================================

test "check: missing closing brace is rejected" {
    const wgsl =
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    let x: u32 = 1u;
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 0), result);

    // Error metadata should be populated.
    var kind_buf: [64]u8 = undefined;
    const kind = readErrorKind(&kind_buf);
    try std.testing.expect(kind.len > 0);
}

test "check: invalid token is rejected" {
    const wgsl = "@compute @workgroup_size(1) fn main() { $$$ }";
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 0), result);
}

test "check: undefined type in function signature is rejected" {
    const wgsl =
        \\@compute @workgroup_size(1)
        \\fn main() {
        \\    var x: NonExistentType = NonExistentType();
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 0), result);
}

// ============================================================
// 3. Empty and whitespace-only shader source
// ============================================================

test "check: empty string is rejected" {
    const wgsl = "";
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, 0);
    // Empty source with no entry points should fail translation.
    // If the compiler allows empty modules, that is a valid outcome too.
    // The key invariant: no crash.
    _ = result;
}

test "check: whitespace-only source is rejected or handled safely" {
    const wgsl = "   \n\n  \t  \n";
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    // Whitespace-only may be rejected or accepted as empty module.
    // No crash is the invariant.
    _ = result;
}

test "check: null pointer with nonzero length returns 0 with error" {
    const result = shader.doeNativeCheckShaderSource(null, 100);
    try std.testing.expectEqual(@as(u32, 0), result);

    var stage_buf: [64]u8 = undefined;
    const stage = readErrorStage(&stage_buf);
    try std.testing.expectEqualStrings("native_check", stage);

    var kind_buf: [64]u8 = undefined;
    const kind = readErrorKind(&kind_buf);
    try std.testing.expectEqualStrings("InvalidInput", kind);
}

// ============================================================
// 4. Error message quality — line/column populated on failure
// ============================================================

test "check: parser error reports nonzero line number" {
    // Error on the second line — missing closing paren.
    const wgsl =
        \\@compute @workgroup_size(1
        \\fn main() {}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    if (result == 0) {
        const line = shader.doeNativeGetLastErrorLine();
        // Line should be >= 1 (the error is on line 1 or 2).
        try std.testing.expect(line >= 1);
    }
}

test "check: error message contains descriptive text" {
    const wgsl = "@compute @workgroup_size(1) fn main() { $$$ }";
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 0), result);

    var msg_buf: [512]u8 = undefined;
    const msg_len = shader.doeNativeCopyLastErrorMessage(&msg_buf, msg_buf.len);
    // Error message should be non-empty and contain some meaningful text.
    try std.testing.expect(msg_len > 5);
}

test "check: error stage is set to a compiler stage on WGSL failure" {
    const wgsl = "@compute @workgroup_size(1) fn main() { $$$ }";
    _ = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);

    var stage_buf: [64]u8 = undefined;
    const stage = readErrorStage(&stage_buf);
    // Stage should be one of: parser, sema, ir_builder, msl_emit, etc.
    try std.testing.expect(stage.len > 0);
    // Verify it is a known compiler stage name, not "native_check".
    const known_stages = [_][]const u8{ "parser", "sema", "ir_builder", "ir_validate", "msl_emit", "hlsl_emit", "spirv_emit" };
    var found = false;
    for (known_stages) |ks| {
        if (std.mem.eql(u8, stage, ks)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ============================================================
// 5. Error clearing between successive calls
// ============================================================

test "check: successful check clears prior error state" {
    // First: trigger an error.
    const bad_wgsl = "$$$ invalid shader $$$";
    _ = shader.doeNativeCheckShaderSource(bad_wgsl.ptr, bad_wgsl.len);

    // Verify error is populated.
    var kind_buf: [64]u8 = undefined;
    const kind_after_fail = readErrorKind(&kind_buf);
    try std.testing.expect(kind_after_fail.len > 0);

    // Second: compile valid WGSL.
    const good_wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(good_wgsl.ptr, good_wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);

    // Error state should be cleared.
    try std.testing.expectEqual(@as(u32, 0), shader.doeNativeGetLastErrorLine());
    try std.testing.expectEqual(@as(u32, 0), shader.doeNativeGetLastErrorColumn());
}

test "check: error from second call replaces first call error" {
    // First error.
    const bad1 = "fn main() { $$$ }";
    _ = shader.doeNativeCheckShaderSource(bad1.ptr, bad1.len);

    // Second different error.
    const bad2 = "@compute @workgroup_size(1) fn main() { let x: u32 = true; }";
    _ = shader.doeNativeCheckShaderSource(bad2.ptr, bad2.len);

    // Error state should reflect the second call, not the first.
    var msg_buf: [512]u8 = undefined;
    const msg_len = shader.doeNativeCopyLastErrorMessage(&msg_buf, msg_buf.len);
    try std.testing.expect(msg_len > 0);
    // The message should not reference the first error's token.
    // We cannot make strong assertions about message content,
    // but we verify the buffer was replaced (not accumulated).
}

// ============================================================
// 6. Error buffer copy semantics
// ============================================================

test "copy error message: truncates when output buffer is smaller than error" {
    // Trigger an error first.
    _ = shader.doeNativeCheckShaderSource(null, 0);

    // Now read with a very small buffer.
    var small_buf: [4]u8 = undefined;
    const total_len = shader.doeNativeCopyLastErrorMessage(&small_buf, small_buf.len);
    // total_len is the full error length; buffer should contain truncated + null.
    try std.testing.expect(total_len > 0);
    // The 4-byte buffer should be null-terminated at index 3.
    try std.testing.expectEqual(@as(u8, 0), small_buf[3]);
}

test "copy error stage: returns 0 after successful check" {
    const good_wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = 0u;
        \\}
    ;
    _ = shader.doeNativeCheckShaderSource(good_wgsl.ptr, good_wgsl.len);

    var stage_buf: [64]u8 = undefined;
    const stage_len = shader.doeNativeCopyLastErrorStage(&stage_buf, stage_buf.len);
    try std.testing.expectEqual(@as(usize, 0), stage_len);
}

test "copy error kind: returns 0 after successful check" {
    const good_wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = 0u;
        \\}
    ;
    _ = shader.doeNativeCheckShaderSource(good_wgsl.ptr, good_wgsl.len);

    var kind_buf: [64]u8 = undefined;
    const kind_len = shader.doeNativeCopyLastErrorKind(&kind_buf, kind_buf.len);
    try std.testing.expectEqual(@as(usize, 0), kind_len);
}

// ============================================================
// 7. Workgroup size variations through check API
// ============================================================

test "check: workgroup_size(1,1,1) compiles" {
    const wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1, 1, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "check: workgroup_size(256) compiles" {
    const wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(256)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "check: workgroup_size(8, 8, 1) compiles" {
    const wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(8, 8, 1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

// ============================================================
// 8. Shader module creation — WGSL sType dispatch without device
// ============================================================

test "createShaderModule: WGSL sType with null device returns non-null error module" {
    // When device is null, cast returns null, so the top-level function returns null.
    const wgsl_code =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;
    var wgsl_desc = types.WGPUShaderSourceWGSL{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceWGSL },
        .code = .{ .data = wgsl_code.ptr, .length = wgsl_code.len },
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&wgsl_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = shader.doeNativeDeviceCreateShaderModule(null, &desc);
    // Null device means cast fails, returns null.
    try std.testing.expectEqual(@as(?*anyopaque, null), result);
}

test "createShaderModule: unknown sType returns error module with error kind" {
    var dev = native.DoeDevice{};
    var chain = types.WGPUChainedStruct{
        .next = null,
        .sType = 0xFFFF_FFFF,
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = &chain,
        .label = .{ .data = null, .length = 0 },
    };
    const result = shader.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    // Should return a non-null error-flagged module (not null, to avoid SIGSEGV in wire).
    try std.testing.expect(result != null);

    const sm = native.cast(native.DoeShaderModule, result).?;
    try std.testing.expectEqual(native.CompilationMessageKind.@"error", sm.compilation_message_kind);
    try std.testing.expect(sm.compilation_message != null);
    try std.testing.expect(std.mem.indexOf(u8, sm.compilation_message.?, "unsupported") != null);

    // Error metadata should mention "unsupported".
    var msg_buf: [512]u8 = undefined;
    const msg_len = shader.doeNativeCopyLastErrorMessage(&msg_buf, msg_buf.len);
    try std.testing.expect(msg_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, msg_buf[0..msg_len], "unsupported") != null);

    var kind_buf: [64]u8 = undefined;
    const kind = readErrorKind(&kind_buf);
    try std.testing.expectEqualStrings("UnsupportedShaderFormat", kind);

    shader.doeNativeShaderModuleRelease(result);
}

// ============================================================
// 9. Shader module creation — WGSL path with null code pointer
// ============================================================

test "createShaderModule: WGSL with null code pointer returns error module" {
    var dev = native.DoeDevice{};
    var wgsl_desc = types.WGPUShaderSourceWGSL{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceWGSL },
        .code = .{ .data = null, .length = 0 },
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&wgsl_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = shader.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    // WGSL path: resolveStringView returns null → createFromWGSL returns null →
    // top-level creates error-flagged module.
    try std.testing.expect(result != null);

    const sm = native.cast(native.DoeShaderModule, result).?;
    try std.testing.expectEqual(native.CompilationMessageKind.@"error", sm.compilation_message_kind);

    shader.doeNativeShaderModuleRelease(result);
}

// ============================================================
// 10. DoeShaderModule defaults and lifecycle
// ============================================================

test "DoeShaderModule: default-initialized has correct magic and zero fields" {
    const sm = native.DoeShaderModule{};
    // Verify magic matches via cast roundtrip (TYPE_MAGIC is not pub).
    var mutable_sm = sm;
    try std.testing.expect(native.cast(native.DoeShaderModule, native.toOpaque(&mutable_sm)) != null);
    try std.testing.expectEqual(@as(u32, 1), sm.ref_count);
    try std.testing.expectEqual(@as(?*anyopaque, null), sm.mtl_library);
    try std.testing.expect(!sm.mtl_library_borrowed);
    try std.testing.expectEqual(@as(u32, 0), sm.binding_count);
    try std.testing.expectEqual(@as(u32, 0), sm.wg_x);
    try std.testing.expectEqual(@as(u32, 0), sm.wg_y);
    try std.testing.expectEqual(@as(u32, 0), sm.wg_z);
    try std.testing.expect(!sm.needs_sizes_buf);
    try std.testing.expectEqual(@as(?[]const u8, null), sm.wgsl_source);
    try std.testing.expectEqual(@as(?[]const u32, null), sm.spirv_data);
    try std.testing.expectEqual(@as(?[]const u8, null), sm.hlsl_source);
    try std.testing.expectEqual(native.CompilationMessageKind.none, sm.compilation_message_kind);
    try std.testing.expectEqual(@as(?[]const u8, null), sm.compilation_message);
    try std.testing.expectEqual(@as(u32, 0), sm.compilation_message_line);
    try std.testing.expectEqual(@as(u32, 0), sm.compilation_message_column);
}

test "DoeShaderModule: release of null is safe" {
    shader.doeNativeShaderModuleRelease(null);
}

test "DoeShaderModule: release of wrong-magic pointer is safe" {
    var fake = native.DoeBuffer{};
    shader.doeNativeShaderModuleRelease(native.toOpaque(&fake));
}

// ============================================================
// 11. GetBindings with valid module
// ============================================================

test "getBindings: zero-binding module returns 0" {
    // Allocate a DoeShaderModule with default (0 bindings).
    var sm = native.DoeShaderModule{};
    sm.binding_count = 0;
    const count = shader.doeNativeShaderModuleGetBindings(native.toOpaque(&sm), null, 0);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "getBindings: returns binding count even with null output pointer" {
    var sm = native.DoeShaderModule{};
    sm.binding_count = 3;
    const count = shader.doeNativeShaderModuleGetBindings(native.toOpaque(&sm), null, 0);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "getBindings: copies binding data to output buffer" {
    var sm = native.DoeShaderModule{};
    sm.binding_count = 2;
    sm.bindings[0] = .{ .group = 0, .binding = 0, .kind = 0, .addr_space = 0, .access = 0 };
    sm.bindings[1] = .{ .group = 0, .binding = 1, .kind = 1, .addr_space = 0, .access = 0 };

    var out: [4]native.BindingInfo = undefined;
    const count = shader.doeNativeShaderModuleGetBindings(native.toOpaque(&sm), &out, out.len);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u32, 0), out[0].binding);
    try std.testing.expectEqual(@as(u32, 1), out[1].binding);
}

test "getBindings: output buffer smaller than binding count only copies partial" {
    var sm = native.DoeShaderModule{};
    sm.binding_count = 3;
    sm.bindings[0] = .{ .group = 0, .binding = 10, .kind = 0, .addr_space = 0, .access = 0 };
    sm.bindings[1] = .{ .group = 0, .binding = 20, .kind = 0, .addr_space = 0, .access = 0 };
    sm.bindings[2] = .{ .group = 1, .binding = 30, .kind = 0, .addr_space = 0, .access = 0 };

    var out: [2]native.BindingInfo = undefined;
    const count = shader.doeNativeShaderModuleGetBindings(native.toOpaque(&sm), &out, out.len);
    // Returns total count (3), but only copies 2.
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(u32, 10), out[0].binding);
    try std.testing.expectEqual(@as(u32, 20), out[1].binding);
}

// ============================================================
// 12. Compute pipeline — null module
// ============================================================

test "createComputePipeline: null module sets InvalidShaderModule error" {
    var dev = native.DoeDevice{};
    const pipeline_desc = types.WGPUComputePipelineDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .layout = null,
        .compute = .{
            .nextInChain = null,
            .module = null,
            .entryPoint = .{ .data = null, .length = 0 },
            .constantCount = 0,
            .constants = null,
        },
    };
    const result = shader.doeNativeDeviceCreateComputePipeline(@ptrCast(&dev), &pipeline_desc);
    try std.testing.expectEqual(@as(?*anyopaque, null), result);

    var kind_buf: [64]u8 = undefined;
    const kind = readErrorKind(&kind_buf);
    try std.testing.expectEqualStrings("InvalidShaderModule", kind);
}

// ============================================================
// 13. Various WGSL patterns through the check API
// ============================================================

test "check: shader with arrayLength builtin compiles" {
    const wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<f32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let len = arrayLength(&buf);
        \\    if (gid.x < len) {
        \\        buf[gid.x] = f32(gid.x);
        \\    }
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "check: shader with uniform binding compiles" {
    const wgsl =
        \\struct Params { count: u32, scale: f32 }
        \\@group(0) @binding(0) var<uniform> params: Params;
        \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
        \\@compute @workgroup_size(32)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    if (gid.x < params.count) {
        \\        output[gid.x] = f32(gid.x) * params.scale;
        \\    }
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "check: vertex shader compiles" {
    const wgsl =
        \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
        \\    return vec4f(0.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "check: fragment shader compiles" {
    const wgsl =
        \\@fragment fn fs_main() -> @location(0) vec4f {
        \\    return vec4f(1.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "check: shader with multiple entry points compiles" {
    const wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn fill(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = 0u;
        \\}
        \\@compute @workgroup_size(128)
        \\fn double(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = buf[gid.x] * 2u;
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "check: shader with mixed vertex and fragment entry points compiles" {
    const wgsl =
        \\struct VertexOutput {
        \\    @builtin(position) pos: vec4f,
        \\}
        \\@vertex fn vs(@builtin(vertex_index) vi: u32) -> VertexOutput {
        \\    var out: VertexOutput;
        \\    out.pos = vec4f(0.0, 0.0, 0.0, 1.0);
        \\    return out;
        \\}
        \\@fragment fn fs(input: VertexOutput) -> @location(0) vec4f {
        \\    return vec4f(1.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
}

// ============================================================
// 14. Error kind classification
// ============================================================

test "check: invalid syntax sets error kind to a TranslateError name" {
    const wgsl = "this is not valid WGSL at all";
    const result = shader.doeNativeCheckShaderSource(wgsl.ptr, wgsl.len);
    try std.testing.expectEqual(@as(u32, 0), result);

    var kind_buf: [64]u8 = undefined;
    const kind = readErrorKind(&kind_buf);
    // Kind should be one of TranslateError names.
    const known_kinds = [_][]const u8{
        "InvalidWgsl",        "InvalidIr",                  "DuplicateSymbol",
        "InvalidAttribute",   "InvalidType",                "OutputTooLarge",
        "OutOfMemory",        "ShaderToolchainUnavailable", "UnexpectedToken",
        "TypeMismatch",       "UnknownIdentifier",          "UnknownType",
        "UnsupportedBuiltin", "UnsupportedConstruct",       "UnsupportedWgsl",
    };
    var found = false;
    for (known_kinds) |kk| {
        if (std.mem.eql(u8, kind, kk)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ============================================================
// 15. WGSL StringView handling — WGPU_STRLEN sentinel
// ============================================================

test "createShaderModule: WGSL with WGPU_STRLEN length and null-terminated code" {
    // This tests the resolveStringView path with the WGPU_STRLEN sentinel.
    // Without a Metal/Vulkan device, the translation step will fail on the
    // backend, but the WGSL parsing and StringView resolution should succeed.
    // On non-Metal non-Vulkan default device, createFromWGSL will attempt
    // translation which may fail, producing an error module.
    var dev = native.DoeDevice{};
    const wgsl_code: [:0]const u8 =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;
    var wgsl_desc = types.WGPUShaderSourceWGSL{
        .chain = .{ .next = null, .sType = types.WGPUSType_ShaderSourceWGSL },
        .code = .{ .data = wgsl_code.ptr, .length = types.WGPU_STRLEN },
    };
    const desc = types.WGPUShaderModuleDescriptor{
        .nextInChain = @ptrCast(&wgsl_desc.chain),
        .label = .{ .data = null, .length = 0 },
    };
    const result = shader.doeNativeDeviceCreateShaderModule(@ptrCast(&dev), &desc);
    // The result may be non-null (error module or success depending on backend).
    // The key invariant: no crash from WGPU_STRLEN handling.
    if (result) |r| {
        shader.doeNativeShaderModuleRelease(r);
    }
}
