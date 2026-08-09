// remaining_modules_test.zig — Tests for token types, device caps constants,
// command parse helpers, and replay validation across the remaining untested
// modules in runtime/zig/src/.

const std = @import("std");
const testing = std.testing;

const token = @import("../../src/compiler/wgsl/frontend/token.zig");
const replay = @import("../../src/runtime/trace/replay.zig");
const command_parse_helpers = @import("../../src/command/command_parse_helpers.zig");
const resource = @import("../../src/contracts/model/model_resource_types.zig");
const compute = @import("../../src/contracts/model/model_compute_types.zig");
const render = @import("../../src/contracts/model/model_render_types.zig");
const gpu = @import("../../src/contracts/model/model_gpu_types.zig");

// ============================================================
// Token — Tag enum structure
// ============================================================

test "Tag enum contains expected punctuation variants" {
    try testing.expectEqual(@as(u8, @intFromEnum(token.Tag.@"(")), @intFromEnum(token.Tag.@"("));
    try testing.expectEqual(@as(u8, @intFromEnum(token.Tag.@")")), @intFromEnum(token.Tag.@")"));
    try testing.expectEqual(@as(u8, @intFromEnum(token.Tag.@"{")), @intFromEnum(token.Tag.@"{"));
    try testing.expectEqual(@as(u8, @intFromEnum(token.Tag.@"}")), @intFromEnum(token.Tag.@"}"));
    try testing.expectEqual(@as(u8, @intFromEnum(token.Tag.@"[")), @intFromEnum(token.Tag.@"["));
    try testing.expectEqual(@as(u8, @intFromEnum(token.Tag.@"]")), @intFromEnum(token.Tag.@"]"));
    try testing.expectEqual(@as(u8, @intFromEnum(token.Tag.@";")), @intFromEnum(token.Tag.@";"));
    try testing.expectEqual(@as(u8, @intFromEnum(token.Tag.@"@")), @intFromEnum(token.Tag.@"@"));
}

test "Tag enum contains operator variants" {
    // Verify compound operators exist and are distinct from single-char.
    const arrow_val = @intFromEnum(token.Tag.arrow);
    const plus_val = @intFromEnum(token.Tag.@"+");
    try testing.expect(arrow_val != plus_val);
    try testing.expect(@intFromEnum(token.Tag.shift_left) != @intFromEnum(token.Tag.@"<"));
    try testing.expect(@intFromEnum(token.Tag.eq_eq) != @intFromEnum(token.Tag.@"="));
}

test "Tag has eof and invalid sentinel values" {
    // These should be distinct tags.
    try testing.expect(@intFromEnum(token.Tag.eof) != @intFromEnum(token.Tag.invalid));
}

// ============================================================
// Token — lookupIdent keyword recognition
// ============================================================

test "lookupIdent recognizes fn keyword" {
    try testing.expectEqual(token.Tag.kw_fn, token.lookupIdent("fn"));
}

test "lookupIdent recognizes var keyword" {
    try testing.expectEqual(token.Tag.kw_var, token.lookupIdent("var"));
}

test "lookupIdent recognizes let keyword" {
    try testing.expectEqual(token.Tag.kw_let, token.lookupIdent("let"));
}

test "lookupIdent recognizes const keyword" {
    try testing.expectEqual(token.Tag.kw_const, token.lookupIdent("const"));
}

test "lookupIdent recognizes for keyword" {
    try testing.expectEqual(token.Tag.kw_for, token.lookupIdent("for"));
}

test "lookupIdent recognizes while keyword" {
    try testing.expectEqual(token.Tag.kw_while, token.lookupIdent("while"));
}

test "lookupIdent recognizes loop keyword" {
    try testing.expectEqual(token.Tag.kw_loop, token.lookupIdent("loop"));
}

test "lookupIdent recognizes if keyword" {
    try testing.expectEqual(token.Tag.kw_if, token.lookupIdent("if"));
}

test "lookupIdent recognizes return keyword" {
    try testing.expectEqual(token.Tag.kw_return, token.lookupIdent("return"));
}

test "lookupIdent recognizes struct keyword" {
    try testing.expectEqual(token.Tag.kw_struct, token.lookupIdent("struct"));
}

test "lookupIdent recognizes type keywords" {
    try testing.expectEqual(token.Tag.kw_bool, token.lookupIdent("bool"));
    try testing.expectEqual(token.Tag.kw_f16, token.lookupIdent("f16"));
    try testing.expectEqual(token.Tag.kw_f32, token.lookupIdent("f32"));
    try testing.expectEqual(token.Tag.kw_i32, token.lookupIdent("i32"));
    try testing.expectEqual(token.Tag.kw_u32, token.lookupIdent("u32"));
    try testing.expectEqual(token.Tag.kw_vec2, token.lookupIdent("vec2"));
    try testing.expectEqual(token.Tag.kw_vec3, token.lookupIdent("vec3"));
    try testing.expectEqual(token.Tag.kw_vec4, token.lookupIdent("vec4"));
    try testing.expectEqual(token.Tag.kw_mat4x4, token.lookupIdent("mat4x4"));
    try testing.expectEqual(token.Tag.kw_array, token.lookupIdent("array"));
}

test "lookupIdent recognizes shorthand type aliases" {
    try testing.expectEqual(token.Tag.kw_vec2f, token.lookupIdent("vec2f"));
    try testing.expectEqual(token.Tag.kw_vec3f, token.lookupIdent("vec3f"));
    try testing.expectEqual(token.Tag.kw_vec4f, token.lookupIdent("vec4f"));
    try testing.expectEqual(token.Tag.kw_vec2u, token.lookupIdent("vec2u"));
    try testing.expectEqual(token.Tag.kw_vec3u, token.lookupIdent("vec3u"));
    try testing.expectEqual(token.Tag.kw_vec4u, token.lookupIdent("vec4u"));
    try testing.expectEqual(token.Tag.kw_vec2i, token.lookupIdent("vec2i"));
    try testing.expectEqual(token.Tag.kw_vec3i, token.lookupIdent("vec3i"));
    try testing.expectEqual(token.Tag.kw_vec4i, token.lookupIdent("vec4i"));
    try testing.expectEqual(token.Tag.kw_vec2h, token.lookupIdent("vec2h"));
    try testing.expectEqual(token.Tag.kw_vec3h, token.lookupIdent("vec3h"));
    try testing.expectEqual(token.Tag.kw_vec4h, token.lookupIdent("vec4h"));
    try testing.expectEqual(token.Tag.kw_mat2x2f, token.lookupIdent("mat2x2f"));
    try testing.expectEqual(token.Tag.kw_mat3x3f, token.lookupIdent("mat3x3f"));
    try testing.expectEqual(token.Tag.kw_mat4x4f, token.lookupIdent("mat4x4f"));
    try testing.expectEqual(token.Tag.kw_mat2x2h, token.lookupIdent("mat2x2h"));
    try testing.expectEqual(token.Tag.kw_mat3x3h, token.lookupIdent("mat3x3h"));
    try testing.expectEqual(token.Tag.kw_mat4x4h, token.lookupIdent("mat4x4h"));
}

test "lookupIdent recognizes address-space keywords" {
    try testing.expectEqual(token.Tag.kw_uniform, token.lookupIdent("uniform"));
    try testing.expectEqual(token.Tag.kw_storage, token.lookupIdent("storage"));
    try testing.expectEqual(token.Tag.kw_workgroup, token.lookupIdent("workgroup"));
    try testing.expectEqual(token.Tag.kw_private, token.lookupIdent("private"));
    try testing.expectEqual(token.Tag.kw_function, token.lookupIdent("function"));
    try testing.expectEqual(token.Tag.kw_read, token.lookupIdent("read"));
    try testing.expectEqual(token.Tag.kw_read_write, token.lookupIdent("read_write"));
}

test "lookupIdent returns ident for unknown words" {
    try testing.expectEqual(token.Tag.ident, token.lookupIdent("myVariable"));
    try testing.expectEqual(token.Tag.ident, token.lookupIdent("foobar"));
    try testing.expectEqual(token.Tag.ident, token.lookupIdent("xyz123"));
}

test "lookupIdent is case sensitive" {
    // WGSL keywords are lowercase only.
    try testing.expectEqual(token.Tag.ident, token.lookupIdent("Fn"));
    try testing.expectEqual(token.Tag.ident, token.lookupIdent("FN"));
    try testing.expectEqual(token.Tag.ident, token.lookupIdent("Var"));
    try testing.expectEqual(token.Tag.ident, token.lookupIdent("IF"));
    try testing.expectEqual(token.Tag.ident, token.lookupIdent("Return"));
}

test "lookupIdent handles empty string as ident" {
    try testing.expectEqual(token.Tag.ident, token.lookupIdent(""));
}

// ============================================================
// Token — Token.slice
// ============================================================

test "Token.slice extracts correct source range" {
    const source = "fn main() {}";
    const tok = token.Token{
        .tag = .kw_fn,
        .loc = .{ .start = 0, .end = 2 },
    };
    try testing.expectEqualStrings("fn", tok.slice(source));
}

test "Token.slice extracts identifier" {
    const source = "fn main() {}";
    const tok = token.Token{
        .tag = .ident,
        .loc = .{ .start = 3, .end = 7 },
    };
    try testing.expectEqualStrings("main", tok.slice(source));
}

// ============================================================
// Command parse helpers — parseCopyResourceKind
// ============================================================

test "parseCopyResourceKind recognizes buffer" {
    try testing.expectEqual(resource.CopyResourceKind.buffer, command_parse_helpers.parseCopyResourceKind("buffer").?);
}

test "parseCopyResourceKind recognizes texture" {
    try testing.expectEqual(resource.CopyResourceKind.texture, command_parse_helpers.parseCopyResourceKind("texture").?);
}

test "parseCopyResourceKind returns null for unknown" {
    try testing.expectEqual(@as(?resource.CopyResourceKind, null), command_parse_helpers.parseCopyResourceKind("unknown"));
}

test "parseCopyResourceKind returns null for null input" {
    try testing.expectEqual(@as(?resource.CopyResourceKind, null), command_parse_helpers.parseCopyResourceKind(null));
}

// ============================================================
// Command parse helpers — parseCopyDirection
// ============================================================

test "parseCopyDirection recognizes explicit directions" {
    try testing.expectEqual(resource.CopyDirection.buffer_to_buffer, try command_parse_helpers.parseCopyDirection("buffer_to_buffer", null));
    try testing.expectEqual(resource.CopyDirection.buffer_to_texture, try command_parse_helpers.parseCopyDirection("buffer_to_texture", null));
    try testing.expectEqual(resource.CopyDirection.texture_to_buffer, try command_parse_helpers.parseCopyDirection("texture_to_buffer", null));
    try testing.expectEqual(resource.CopyDirection.texture_to_texture, try command_parse_helpers.parseCopyDirection("texture_to_texture", null));
}

test "parseCopyDirection infers from command name" {
    try testing.expectEqual(resource.CopyDirection.buffer_to_texture, try command_parse_helpers.parseCopyDirection(null, "copy_buffer_to_texture"));
    try testing.expectEqual(resource.CopyDirection.texture_to_buffer, try command_parse_helpers.parseCopyDirection(null, "copy_texture_to_buffer"));
    try testing.expectEqual(resource.CopyDirection.texture_to_texture, try command_parse_helpers.parseCopyDirection(null, "copy_texture_to_texture"));
}

test "parseCopyDirection defaults to buffer_to_buffer" {
    try testing.expectEqual(resource.CopyDirection.buffer_to_buffer, try command_parse_helpers.parseCopyDirection(null, null));
}

test "parseCopyDirection rejects invalid direction string" {
    try testing.expectError(error.InvalidCommandPayload, command_parse_helpers.parseCopyDirection("invalid_direction", null));
}

// ============================================================
// Command parse helpers — parseKernelBindingKind
// ============================================================

test "parseKernelBindingKind defaults to buffer for null" {
    try testing.expectEqual(compute.KernelBindingResourceKind.buffer, command_parse_helpers.parseKernelBindingKind(null).?);
}

test "parseKernelBindingKind recognizes buffer variants" {
    try testing.expectEqual(compute.KernelBindingResourceKind.buffer, command_parse_helpers.parseKernelBindingKind("buffer").?);
    try testing.expectEqual(compute.KernelBindingResourceKind.buffer, command_parse_helpers.parseKernelBindingKind("uniform").?);
    try testing.expectEqual(compute.KernelBindingResourceKind.buffer, command_parse_helpers.parseKernelBindingKind("storage_buffer").?);
}

test "parseKernelBindingKind recognizes texture" {
    try testing.expectEqual(compute.KernelBindingResourceKind.texture, command_parse_helpers.parseKernelBindingKind("texture").?);
    try testing.expectEqual(compute.KernelBindingResourceKind.texture, command_parse_helpers.parseKernelBindingKind("sampled_texture").?);
}

test "parseKernelBindingKind recognizes storage texture" {
    try testing.expectEqual(compute.KernelBindingResourceKind.storage_texture, command_parse_helpers.parseKernelBindingKind("storage_texture").?);
}

test "parseKernelBindingKind recognizes sampler" {
    try testing.expectEqual(compute.KernelBindingResourceKind.sampler, command_parse_helpers.parseKernelBindingKind("sampler").?);
    try testing.expectEqual(compute.KernelBindingResourceKind.sampler, command_parse_helpers.parseKernelBindingKind("filtering_sampler").?);
    try testing.expectEqual(compute.KernelBindingResourceKind.sampler, command_parse_helpers.parseKernelBindingKind("comparison_sampler").?);
}

test "parseKernelBindingKind returns null for unknown" {
    try testing.expectEqual(@as(?compute.KernelBindingResourceKind, null), command_parse_helpers.parseKernelBindingKind("invalid"));
}

// ============================================================
// Command parse helpers — parseShaderStage
// ============================================================

test "parseShaderStage recognizes compute" {
    try testing.expectEqual(gpu.WGPUShaderStage_Compute, command_parse_helpers.parseShaderStage("compute").?);
}

test "parseShaderStage recognizes vertex" {
    try testing.expectEqual(gpu.WGPUShaderStage_Vertex, command_parse_helpers.parseShaderStage("vertex").?);
}

test "parseShaderStage recognizes fragment" {
    try testing.expectEqual(gpu.WGPUShaderStage_Fragment, command_parse_helpers.parseShaderStage("fragment").?);
}

test "parseShaderStage recognizes all" {
    const all = command_parse_helpers.parseShaderStage("all").?;
    try testing.expect(all & gpu.WGPUShaderStage_Vertex != 0);
    try testing.expect(all & gpu.WGPUShaderStage_Fragment != 0);
    try testing.expect(all & gpu.WGPUShaderStage_Compute != 0);
}

test "parseShaderStage returns null for unknown" {
    try testing.expectEqual(@as(?gpu.WGPUFlags, null), command_parse_helpers.parseShaderStage("pixel"));
}

test "parseShaderStage returns null for null" {
    try testing.expectEqual(@as(?gpu.WGPUFlags, null), command_parse_helpers.parseShaderStage(null));
}

// ============================================================
// Command parse helpers — parseBufferBindingType
// ============================================================

test "parseBufferBindingType recognizes types" {
    try testing.expectEqual(gpu.WGPUBufferBindingType_Uniform, command_parse_helpers.parseBufferBindingType("uniform"));
    try testing.expectEqual(gpu.WGPUBufferBindingType_Storage, command_parse_helpers.parseBufferBindingType("storage"));
    try testing.expectEqual(gpu.WGPUBufferBindingType_ReadOnlyStorage, command_parse_helpers.parseBufferBindingType("readonly"));
    try testing.expectEqual(gpu.WGPUBufferBindingType_ReadOnlyStorage, command_parse_helpers.parseBufferBindingType("read_only_storage"));
}

test "parseBufferBindingType defaults to undefined" {
    try testing.expectEqual(gpu.WGPUBufferBindingType_Undefined, command_parse_helpers.parseBufferBindingType(null));
    try testing.expectEqual(gpu.WGPUBufferBindingType_Undefined, command_parse_helpers.parseBufferBindingType("unknown"));
}

// ============================================================
// Command parse helpers — parseTextureSampleType
// ============================================================

test "parseTextureSampleType recognizes types" {
    try testing.expectEqual(gpu.WGPUTextureSampleType_Float, command_parse_helpers.parseTextureSampleType("float"));
    try testing.expectEqual(gpu.WGPUTextureSampleType_UnfilterableFloat, command_parse_helpers.parseTextureSampleType("unfilterable-float"));
    try testing.expectEqual(gpu.WGPUTextureSampleType_UnfilterableFloat, command_parse_helpers.parseTextureSampleType("unfilterable_float"));
    try testing.expectEqual(gpu.WGPUTextureSampleType_Depth, command_parse_helpers.parseTextureSampleType("depth"));
    try testing.expectEqual(gpu.WGPUTextureSampleType_Sint, command_parse_helpers.parseTextureSampleType("sint"));
    try testing.expectEqual(gpu.WGPUTextureSampleType_Uint, command_parse_helpers.parseTextureSampleType("uint"));
}

test "parseTextureSampleType defaults to undefined" {
    try testing.expectEqual(gpu.WGPUTextureSampleType_Undefined, command_parse_helpers.parseTextureSampleType(null));
}

// ============================================================
// Command parse helpers — parseTextureViewDimension
// ============================================================

test "parseTextureViewDimension recognizes dimensions" {
    try testing.expectEqual(gpu.WGPUTextureViewDimension_1D, command_parse_helpers.parseTextureViewDimension("1d"));
    try testing.expectEqual(gpu.WGPUTextureViewDimension_2D, command_parse_helpers.parseTextureViewDimension("2d"));
    try testing.expectEqual(gpu.WGPUTextureViewDimension_2DArray, command_parse_helpers.parseTextureViewDimension("2d-array"));
    try testing.expectEqual(gpu.WGPUTextureViewDimension_Cube, command_parse_helpers.parseTextureViewDimension("cube"));
    try testing.expectEqual(gpu.WGPUTextureViewDimension_CubeArray, command_parse_helpers.parseTextureViewDimension("cube-array"));
    try testing.expectEqual(gpu.WGPUTextureViewDimension_3D, command_parse_helpers.parseTextureViewDimension("3d"));
}

test "parseTextureViewDimension defaults to undefined" {
    try testing.expectEqual(gpu.WGPUTextureViewDimension_Undefined, command_parse_helpers.parseTextureViewDimension(null));
}

// ============================================================
// Command parse helpers — parseTextureDimension
// ============================================================

test "parseTextureDimension recognizes dimensions" {
    try testing.expectEqual(gpu.WGPUTextureDimension_1D, command_parse_helpers.parseTextureDimension("1d"));
    try testing.expectEqual(gpu.WGPUTextureDimension_2D, command_parse_helpers.parseTextureDimension("2d"));
    try testing.expectEqual(gpu.WGPUTextureDimension_3D, command_parse_helpers.parseTextureDimension("3d"));
}

test "parseTextureDimension defaults to undefined" {
    try testing.expectEqual(gpu.WGPUTextureDimension_Undefined, command_parse_helpers.parseTextureDimension(null));
}

// ============================================================
// Command parse helpers — parseStorageTextureAccess
// ============================================================

test "parseStorageTextureAccess recognizes modes" {
    try testing.expectEqual(gpu.WGPUStorageTextureAccess_WriteOnly, command_parse_helpers.parseStorageTextureAccess("write_only"));
    try testing.expectEqual(gpu.WGPUStorageTextureAccess_WriteOnly, command_parse_helpers.parseStorageTextureAccess("write-only"));
    try testing.expectEqual(gpu.WGPUStorageTextureAccess_ReadOnly, command_parse_helpers.parseStorageTextureAccess("read_only"));
    try testing.expectEqual(gpu.WGPUStorageTextureAccess_ReadOnly, command_parse_helpers.parseStorageTextureAccess("read-only"));
    try testing.expectEqual(gpu.WGPUStorageTextureAccess_ReadWrite, command_parse_helpers.parseStorageTextureAccess("read_write"));
    try testing.expectEqual(gpu.WGPUStorageTextureAccess_ReadWrite, command_parse_helpers.parseStorageTextureAccess("read-write"));
}

test "parseStorageTextureAccess defaults to undefined" {
    try testing.expectEqual(gpu.WGPUStorageTextureAccess_Undefined, command_parse_helpers.parseStorageTextureAccess(null));
}

// ============================================================
// Command parse helpers — parseTextureAspect
// ============================================================

test "parseTextureAspect recognizes aspects" {
    try testing.expectEqual(gpu.WGPUTextureAspect_All, command_parse_helpers.parseTextureAspect("all"));
    try testing.expectEqual(gpu.WGPUTextureAspect_DepthOnly, command_parse_helpers.parseTextureAspect("depth-only"));
    try testing.expectEqual(gpu.WGPUTextureAspect_DepthOnly, command_parse_helpers.parseTextureAspect("depth_only"));
    try testing.expectEqual(gpu.WGPUTextureAspect_DepthOnly, command_parse_helpers.parseTextureAspect("depth"));
    try testing.expectEqual(gpu.WGPUTextureAspect_StencilOnly, command_parse_helpers.parseTextureAspect("stencil-only"));
    try testing.expectEqual(gpu.WGPUTextureAspect_StencilOnly, command_parse_helpers.parseTextureAspect("stencil_only"));
    try testing.expectEqual(gpu.WGPUTextureAspect_StencilOnly, command_parse_helpers.parseTextureAspect("stencil"));
}

test "parseTextureAspect defaults to undefined" {
    try testing.expectEqual(gpu.WGPUTextureAspect_Undefined, command_parse_helpers.parseTextureAspect(null));
}

// ============================================================
// Command parse helpers — parseTextureFormat
// ============================================================

test "parseTextureFormat recognizes common formats" {
    try testing.expectEqual(gpu.WGPUTextureFormat_RGBA8Unorm, try command_parse_helpers.parseTextureFormat("rgba8unorm"));
    try testing.expectEqual(gpu.WGPUTextureFormat_BGRA8Unorm, try command_parse_helpers.parseTextureFormat("bgra8unorm"));
    try testing.expectEqual(gpu.WGPUTextureFormat_R32Float, try command_parse_helpers.parseTextureFormat("r32float"));
    try testing.expectEqual(gpu.WGPUTextureFormat_Depth32Float, try command_parse_helpers.parseTextureFormat("depth32float"));
    try testing.expectEqual(gpu.WGPUTextureFormat_Depth24PlusStencil8, try command_parse_helpers.parseTextureFormat("depth24plus-stencil8"));
}

test "parseTextureFormat returns undefined for empty string" {
    try testing.expectEqual(gpu.WGPUTextureFormat_Undefined, try command_parse_helpers.parseTextureFormat(""));
}

test "parseTextureFormat rejects invalid format name" {
    try testing.expectError(error.InvalidCommandPayload, command_parse_helpers.parseTextureFormat("not_a_format"));
}

test "parseTextureFormat is case insensitive" {
    try testing.expectEqual(gpu.WGPUTextureFormat_RGBA8Unorm, try command_parse_helpers.parseTextureFormat("RGBA8Unorm"));
    try testing.expectEqual(gpu.WGPUTextureFormat_RGBA8Unorm, try command_parse_helpers.parseTextureFormat("RGBA8UNORM"));
}

// ============================================================
// Command parse helpers — parseRenderDrawPipelineMode
// ============================================================

test "parseRenderDrawPipelineMode recognizes modes" {
    try testing.expectEqual(render.RenderDrawPipelineMode.static, try command_parse_helpers.parseRenderDrawPipelineMode(null));
    try testing.expectEqual(render.RenderDrawPipelineMode.static, try command_parse_helpers.parseRenderDrawPipelineMode("static"));
    try testing.expectEqual(render.RenderDrawPipelineMode.redundant, try command_parse_helpers.parseRenderDrawPipelineMode("redundant"));
}

test "parseRenderDrawPipelineMode rejects unknown mode" {
    try testing.expectError(error.InvalidCommandPayload, command_parse_helpers.parseRenderDrawPipelineMode("invalid"));
}

// ============================================================
// Command parse helpers — parseRenderDrawBindGroupMode
// ============================================================

test "parseRenderDrawBindGroupMode recognizes modes" {
    try testing.expectEqual(render.RenderDrawBindGroupMode.no_change, try command_parse_helpers.parseRenderDrawBindGroupMode(null));
    try testing.expectEqual(render.RenderDrawBindGroupMode.no_change, try command_parse_helpers.parseRenderDrawBindGroupMode("no-change"));
    try testing.expectEqual(render.RenderDrawBindGroupMode.no_change, try command_parse_helpers.parseRenderDrawBindGroupMode("no_change"));
    try testing.expectEqual(render.RenderDrawBindGroupMode.redundant, try command_parse_helpers.parseRenderDrawBindGroupMode("redundant"));
}

test "parseRenderDrawBindGroupMode rejects unknown mode" {
    try testing.expectError(error.InvalidCommandPayload, command_parse_helpers.parseRenderDrawBindGroupMode("invalid"));
}

// ============================================================
// Command parse helpers — parseRenderIndexFormat
// ============================================================

test "parseRenderIndexFormat recognizes formats" {
    const uint16 = try command_parse_helpers.parseRenderIndexFormat("uint16");
    try testing.expectEqual(render.RenderIndexFormat.uint16, uint16.?);
    const uint32 = try command_parse_helpers.parseRenderIndexFormat("uint32");
    try testing.expectEqual(render.RenderIndexFormat.uint32, uint32.?);
    const u16_alias = try command_parse_helpers.parseRenderIndexFormat("u16");
    try testing.expectEqual(render.RenderIndexFormat.uint16, u16_alias.?);
    const u32_alias = try command_parse_helpers.parseRenderIndexFormat("u32");
    try testing.expectEqual(render.RenderIndexFormat.uint32, u32_alias.?);
}

test "parseRenderIndexFormat returns null for null input" {
    try testing.expectEqual(@as(?render.RenderIndexFormat, null), try command_parse_helpers.parseRenderIndexFormat(null));
}

test "parseRenderIndexFormat rejects unknown format" {
    try testing.expectError(error.InvalidCommandPayload, command_parse_helpers.parseRenderIndexFormat("float32"));
}

// ============================================================
// Command parse helpers — parseRenderIndexData
// ============================================================

test "parseRenderIndexData infers uint16 for small indices" {
    const indices = [_]u32{ 0, 1, 2, 3, 100, 65535 };
    const result = try command_parse_helpers.parseRenderIndexData(testing.allocator, &indices, null);
    const u16_data = switch (result) {
        .uint16 => |d| d,
        else => return error.TestUnexpectedResult,
    };
    defer testing.allocator.free(u16_data);
    try testing.expectEqual(@as(usize, 6), u16_data.len);
    try testing.expectEqual(@as(u16, 0), u16_data[0]);
    try testing.expectEqual(@as(u16, 65535), u16_data[5]);
}

test "parseRenderIndexData infers uint32 for large indices" {
    const indices = [_]u32{ 0, 65536, 100000 };
    const result = try command_parse_helpers.parseRenderIndexData(testing.allocator, &indices, null);
    const u32_data = switch (result) {
        .uint32 => |d| d,
        else => return error.TestUnexpectedResult,
    };
    defer testing.allocator.free(u32_data);
    try testing.expectEqual(@as(usize, 3), u32_data.len);
    try testing.expectEqual(@as(u32, 65536), u32_data[1]);
}

test "parseRenderIndexData respects explicit uint32 request" {
    const indices = [_]u32{ 0, 1, 2 };
    const result = try command_parse_helpers.parseRenderIndexData(testing.allocator, &indices, .uint32);
    const u32_data = switch (result) {
        .uint32 => |d| d,
        else => return error.TestUnexpectedResult,
    };
    defer testing.allocator.free(u32_data);
    try testing.expectEqual(@as(usize, 3), u32_data.len);
}

test "parseRenderIndexData rejects overflow when uint16 forced" {
    const indices = [_]u32{ 0, 70000 };
    try testing.expectError(error.InvalidCommandPayload, command_parse_helpers.parseRenderIndexData(testing.allocator, &indices, .uint16));
}

// ============================================================
// Replay — parseTraceHash
// ============================================================

test "parseTraceHash parses plain hex" {
    try testing.expectEqual(@as(u64, 0xdeadbeef), try replay.parseTraceHash("deadbeef"));
}

test "parseTraceHash parses 0x prefix" {
    try testing.expectEqual(@as(u64, 0xCAFE), try replay.parseTraceHash("0xCAFE"));
}

test "parseTraceHash parses 0X prefix" {
    try testing.expectEqual(@as(u64, 0x1a2b), try replay.parseTraceHash("0X1a2b"));
}

test "parseTraceHash rejects empty string" {
    try testing.expectError(replay.ReplayValidationError.InvalidReplayHash, replay.parseTraceHash(""));
}

test "parseTraceHash rejects non-hex" {
    try testing.expectError(replay.ReplayValidationError.InvalidReplayHash, replay.parseTraceHash("zzzz"));
}

test "parseTraceHash handles max u64" {
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), try replay.parseTraceHash("FFFFFFFFFFFFFFFF"));
}

test "parseTraceHash handles single digit" {
    try testing.expectEqual(@as(u64, 0xA), try replay.parseTraceHash("a"));
}

// ============================================================
// Replay — matchOptionalText
// ============================================================

test "matchOptionalText both null returns true" {
    try testing.expect(replay.matchOptionalText(null, null));
}

test "matchOptionalText one null returns false" {
    try testing.expect(!replay.matchOptionalText("a", null));
    try testing.expect(!replay.matchOptionalText(null, "a"));
}

test "matchOptionalText matching strings returns true" {
    try testing.expect(replay.matchOptionalText("hello", "hello"));
}

test "matchOptionalText different strings returns false" {
    try testing.expect(!replay.matchOptionalText("hello", "world"));
}

test "matchOptionalText empty strings returns true" {
    try testing.expect(replay.matchOptionalText("", ""));
}

// ============================================================
// Replay — parseReplayLine
// ============================================================

test "parseReplayLine accepts valid row" {
    const row = replay.RawReplayRow{
        .seq = 0,
        .command = "compute",
        .kernel = "add_kernel",
        .hash = "0xabc",
        .previousHash = "0x0",
        .opCode = "dispatch",
        .module = "doe-zig-runtime",
    };
    const result = try replay.parseReplayLine("doe-zig-runtime", &row);
    try testing.expectEqual(@as(usize, 0), result.seq);
    try testing.expectEqualStrings("compute", result.command);
    try testing.expectEqualStrings("add_kernel", result.kernel.?);
    try testing.expectEqual(@as(u64, 0xabc), result.hash);
    try testing.expectEqual(@as(u64, 0x0), result.previous_hash);
}

test "parseReplayLine rejects mismatched module" {
    const row = replay.RawReplayRow{
        .seq = 1,
        .command = "dispatch",
        .hash = "ff",
        .previousHash = "00",
        .module = "wrong-module",
    };
    try testing.expectError(replay.ReplayValidationError.ReplayArtifactModuleMismatch, replay.parseReplayLine("doe-zig-runtime", &row));
}

test "parseReplayLine rejects mismatched opCode" {
    const row = replay.RawReplayRow{
        .seq = 1,
        .command = "dispatch",
        .hash = "ff",
        .previousHash = "00",
        .opCode = "render",
    };
    try testing.expectError(replay.ReplayValidationError.ReplayArtifactOpCodeMismatch, replay.parseReplayLine("doe-zig-runtime", &row));
}

test "parseReplayLine rejects missing command" {
    const row = replay.RawReplayRow{ .seq = 0, .hash = "aa", .previousHash = "00" };
    try testing.expectError(replay.ReplayValidationError.ReplayCommandFieldMissing, replay.parseReplayLine("x", &row));
}

test "parseReplayLine rejects missing hash" {
    const row = replay.RawReplayRow{ .seq = 0, .command = "c", .previousHash = "00" };
    try testing.expectError(replay.ReplayValidationError.ReplayHashFieldMissing, replay.parseReplayLine("x", &row));
}

test "parseReplayLine rejects missing previousHash" {
    const row = replay.RawReplayRow{ .seq = 0, .command = "c", .hash = "aa" };
    try testing.expectError(replay.ReplayValidationError.ReplayPreviousHashFieldMissing, replay.parseReplayLine("x", &row));
}

test "parseReplayLine rejects missing seq" {
    const row = replay.RawReplayRow{ .command = "c", .hash = "aa", .previousHash = "00" };
    try testing.expectError(replay.ReplayValidationError.ReplaySeqFieldMissing, replay.parseReplayLine("x", &row));
}

// ============================================================
// Replay — ReplayValidationError enum
// ============================================================

test "ReplayValidationError has expected variant count" {
    const fields = @typeInfo(replay.ReplayValidationError).error_set.?;
    // 14 error variants defined.
    try testing.expectEqual(@as(usize, 14), fields.len);
}

// ============================================================
// DXIL spec constants — basic structure
// ============================================================

test "DXIL spec BITCODE_MAGIC is correct" {
    const dxil_spec = @import("../../src/compiler/wgsl/emit/dxil/dxil_spec.zig");
    try testing.expectEqual(@as(u32, 0x4243_C0DE), dxil_spec.BITCODE_MAGIC);
}

test "DXIL spec LLVM_IR_MAGIC bytes are correct" {
    const dxil_spec = @import("../../src/compiler/wgsl/emit/dxil/dxil_spec.zig");
    try testing.expectEqualSlices(u8, &.{ 'B', 'C', 0xC0, 0xDE }, &dxil_spec.LLVM_IR_MAGIC);
}

test "DXIL BlockId constants are distinct" {
    const BlockId = @import("../../src/compiler/wgsl/emit/dxil/dxil_spec.zig").BlockId;
    try testing.expect(BlockId.MODULE != BlockId.PARAMATTR);
    try testing.expect(BlockId.CONSTANTS != BlockId.FUNCTION);
    try testing.expect(BlockId.TYPE != BlockId.METADATA);
    try testing.expectEqual(@as(u32, 8), BlockId.MODULE);
    try testing.expectEqual(@as(u32, 11), BlockId.CONSTANTS);
    try testing.expectEqual(@as(u32, 12), BlockId.FUNCTION);
    try testing.expectEqual(@as(u32, 17), BlockId.TYPE);
}

test "DXIL AbbrevId sentinel values" {
    const AbbrevId = @import("../../src/compiler/wgsl/emit/dxil/dxil_spec.zig").AbbrevId;
    try testing.expectEqual(@as(u32, 0), AbbrevId.END_BLOCK);
    try testing.expectEqual(@as(u32, 1), AbbrevId.ENTER_SUBBLOCK);
    try testing.expectEqual(@as(u32, 2), AbbrevId.DEFINE_ABBREV);
    try testing.expectEqual(@as(u32, 3), AbbrevId.UNABBREV_RECORD);
}
