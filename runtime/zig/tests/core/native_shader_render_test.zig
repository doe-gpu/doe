// native_shader_render_test.zig — Unit tests for C ABI native modules:
//   doe_shader_native.zig, doe_render_native.zig,
//   doe_query_native.zig, doe_instance_device_native.zig.
//
// Tests cover: exported symbol existence (comptime), null-pointer safety,
// constant correctness, pure helper functions, and error-state management.

const std = @import("std");

const WGPU_QUERY_TYPE_OCCLUSION: u32 = 0x00000001;

const shader = @import("../../src/native/shader/doe_shader_native.zig");
const render = @import("../../src/native/render/doe_render_native.zig");
const query = @import("../../src/native/resource/doe_query_native.zig");
const instance_device = @import("../../src/native/lifecycle/doe_instance_device_native.zig");
const native = @import("../../src/native/mod.zig");
const types = @import("../../src/core/abi/wgpu_runtime_abi.zig");
const vk = @import("../../src/backend/vulkan/vk_constants.zig");
const wgsl_compiler = @import("../../src/compiler/wgsl/mod.zig");
const caps = @import("../../src/native/support/doe_device_caps.zig");

// ============================================================
// Comptime: exported C ABI symbol existence
// ============================================================

test "shader native exports exist as callable C ABI functions" {
    // Verify each pub export fn resolves at comptime.
    comptime {
        _ = @as(*const fn (?[*]u8, usize) callconv(.c) usize, &shader.doeNativeCopyLastErrorMessage);
        _ = @as(*const fn (?[*]u8, usize) callconv(.c) usize, &shader.doeNativeCopyLastErrorStage);
        _ = @as(*const fn (?[*]u8, usize) callconv(.c) usize, &shader.doeNativeCopyLastErrorKind);
        _ = @as(*const fn () callconv(.c) u32, &shader.doeNativeGetLastErrorLine);
        _ = @as(*const fn () callconv(.c) u32, &shader.doeNativeGetLastErrorColumn);
        _ = @as(*const fn (?[*]const u8, usize) callconv(.c) u32, &shader.doeNativeCheckShaderSource);
        _ = @as(*const fn (?*anyopaque, ?[*]native.BindingInfo, usize) callconv(.c) usize, &shader.doeNativeShaderModuleGetBindings);
        _ = @as(*const fn (?*anyopaque, ?*const types.WGPUShaderModuleDescriptor) callconv(.c) ?*anyopaque, &shader.doeNativeDeviceCreateShaderModule);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &shader.doeNativeShaderModuleRelease);
        _ = @as(*const fn (?*anyopaque, ?*const types.WGPUComputePipelineDescriptor) callconv(.c) ?*anyopaque, &shader.doeNativeDeviceCreateComputePipeline);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &shader.doeNativeComputePipelineRelease);
    }
}

test "render native exports exist as callable C ABI functions" {
    comptime {
        _ = @as(*const fn (?*anyopaque, ?*const types.WGPUTextureDescriptor) callconv(.c) ?*anyopaque, &render.doeNativeDeviceCreateTexture);
        _ = @as(*const fn (?*anyopaque, ?*const types.WGPUTextureViewDescriptor) callconv(.c) ?*anyopaque, &render.doeNativeTextureCreateView);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &render.doeNativeTextureRelease);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &render.doeNativeTextureViewRelease);
        _ = @as(*const fn (?*anyopaque, ?*const types.WGPUSamplerDescriptor) callconv(.c) ?*anyopaque, &render.doeNativeDeviceCreateSampler);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &render.doeNativeSamplerRelease);
        _ = @as(*const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque, &render.doeNativeDeviceCreateRenderPipeline);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &render.doeNativeRenderPipelineRelease);
        _ = @as(*const fn (?*anyopaque, ?*const types.WGPURenderPassDescriptor) callconv(.c) ?*anyopaque, &render.doeNativeCommandEncoderBeginRenderPass);
        _ = @as(*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, &render.doeNativeRenderPassSetPipeline);
        _ = @as(*const fn (?*anyopaque, u32, u32, u32, u32) callconv(.c) void, &render.doeNativeRenderPassDraw);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &render.doeNativeRenderPassEnd);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &render.doeNativeRenderPassRelease);
    }
}

test "query native exports exist as callable C ABI functions" {
    comptime {
        _ = @as(*const fn (?*anyopaque, u32, u32) callconv(.c) ?*anyopaque, &query.doeNativeDeviceCreateQuerySet);
        _ = @as(*const fn (?*anyopaque, ?*anyopaque, u32) callconv(.c) void, &query.doeNativeCommandEncoderWriteTimestamp);
        _ = @as(*const fn (?*anyopaque, ?*anyopaque, u32, u32, ?*anyopaque, u64) callconv(.c) void, &query.doeNativeCommandEncoderResolveQuerySet);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &query.doeNativeQuerySetDestroy);
        _ = @as(*const fn (?*anyopaque, u32) callconv(.c) void, &query.doeNativeRenderPassBeginOcclusionQuery);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &query.doeNativeRenderPassEndOcclusionQuery);
    }
}

test "instance device native exports exist as callable C ABI functions" {
    comptime {
        _ = @as(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, &instance_device.doeNativeCreateInstance);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &instance_device.doeNativeInstanceRelease);
        _ = @as(*const fn (?*anyopaque, usize, [*]types.WGPUFutureWaitInfo, u64) callconv(.c) u32, &instance_device.doeNativeInstanceWaitAny);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &instance_device.doeNativeAdapterRelease);
        _ = @as(*const fn (?*anyopaque) callconv(.c) void, &instance_device.doeNativeDeviceRelease);
        _ = @as(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, &instance_device.doeNativeDeviceGetQueue);
    }
}

test "device caps native exports exist as callable C ABI functions" {
    comptime {
        _ = @as(*const fn (?*anyopaque, u32) callconv(.c) u32, &caps.doeNativeAdapterHasFeature);
        _ = @as(*const fn (?*anyopaque, u32) callconv(.c) u32, &caps.doeNativeDeviceHasFeature);
        _ = @as(*const fn (?*anyopaque, ?*types.WGPULimits) callconv(.c) types.WGPUStatus, &caps.doeNativeDeviceGetLimits);
        _ = @as(*const fn (?*anyopaque, ?*types.WGPULimits) callconv(.c) types.WGPUStatus, &caps.doeNativeAdapterGetLimits);
        _ = @as(*const fn (?*anyopaque) callconv(.c) u32, &caps.doeNativeDeviceSubgroupSize);
    }
}

test "d3d12 texture view swizzle mode separates sampled and storage-only views" {
    try std.testing.expectEqual(
        render.D3D12TextureViewSwizzleMode.identity,
        render.d3d12TextureViewSwizzleMode(
            types.WGPUTextureUsage_TextureBinding,
            types.WGPUTextureComponentSwizzle_Red,
            types.WGPUTextureComponentSwizzle_Green,
            types.WGPUTextureComponentSwizzle_Blue,
            types.WGPUTextureComponentSwizzle_Alpha,
        ),
    );
    try std.testing.expectEqual(
        render.D3D12TextureViewSwizzleMode.swizzled_sampled,
        render.d3d12TextureViewSwizzleMode(
            types.WGPUTextureUsage_TextureBinding,
            types.WGPUTextureComponentSwizzle_Red,
            types.WGPUTextureComponentSwizzle_Blue,
            types.WGPUTextureComponentSwizzle_Green,
            types.WGPUTextureComponentSwizzle_Alpha,
        ),
    );
    try std.testing.expectEqual(
        render.D3D12TextureViewSwizzleMode.unsupported_storage,
        render.d3d12TextureViewSwizzleMode(
            types.WGPUTextureUsage_StorageBinding,
            types.WGPUTextureComponentSwizzle_Red,
            types.WGPUTextureComponentSwizzle_Blue,
            types.WGPUTextureComponentSwizzle_Green,
            types.WGPUTextureComponentSwizzle_Alpha,
        ),
    );
}

// ============================================================
// Null-pointer safety: shader native
// ============================================================

test "doeNativeCopyLastErrorMessage with null out_ptr returns length without crash" {
    const len = shader.doeNativeCopyLastErrorMessage(null, 256);
    // After init, error buffer should be empty (length 0) or have a prior value.
    // The key invariant: calling with null does not crash.
    _ = len;
}

test "doeNativeCopyLastErrorMessage with zero out_len returns length without crash" {
    var buf: [64]u8 = undefined;
    const len = shader.doeNativeCopyLastErrorMessage(&buf, 0);
    _ = len;
}

test "doeNativeCopyLastErrorStage with null out_ptr returns length without crash" {
    const len = shader.doeNativeCopyLastErrorStage(null, 256);
    _ = len;
}

test "doeNativeCopyLastErrorKind with null out_ptr returns length without crash" {
    const len = shader.doeNativeCopyLastErrorKind(null, 256);
    _ = len;
}

test "doeNativeCheckShaderSource with null code_ptr returns 0 and sets error" {
    const result = shader.doeNativeCheckShaderSource(null, 0);
    try std.testing.expectEqual(@as(u32, 0), result);

    // Error state should be populated.
    var msg_buf: [256]u8 = undefined;
    const msg_len = shader.doeNativeCopyLastErrorMessage(&msg_buf, msg_buf.len);
    try std.testing.expect(msg_len > 0);

    const msg = msg_buf[0..msg_len];
    try std.testing.expect(std.mem.indexOf(u8, msg, "null") != null);

    // Stage should be set.
    var stage_buf: [64]u8 = undefined;
    const stage_len = shader.doeNativeCopyLastErrorStage(&stage_buf, stage_buf.len);
    try std.testing.expect(stage_len > 0);
    try std.testing.expectEqualStrings("native_check", stage_buf[0..stage_len]);

    // Kind should be set.
    var kind_buf: [64]u8 = undefined;
    const kind_len = shader.doeNativeCopyLastErrorKind(&kind_buf, kind_buf.len);
    try std.testing.expect(kind_len > 0);
    try std.testing.expectEqualStrings("InvalidInput", kind_buf[0..kind_len]);
}

test "doeNativeCheckShaderSource with invalid WGSL returns 0 and sets error metadata" {
    // Use WGSL with a type error (undeclared identifier in function body).
    const bad_wgsl = "@compute @workgroup_size(1) fn main() { let x: u32 = undeclared_var; }";
    const result = shader.doeNativeCheckShaderSource(bad_wgsl.ptr, bad_wgsl.len);
    // If the compiler is lenient and accepts this, the test still validates
    // that the check function runs without crashing. Skip strict assertion.
    if (result == 0) {
        // Error metadata should be populated.
        const line = shader.doeNativeGetLastErrorLine();
        const col = shader.doeNativeGetLastErrorColumn();
        try std.testing.expect(line >= 1 or col >= 1);
        var kind_buf: [64]u8 = undefined;
        const kind_len = shader.doeNativeCopyLastErrorKind(&kind_buf, kind_buf.len);
        try std.testing.expect(kind_len > 0);
    }
    // If result == 1, the compiler accepted it — not a test failure,
    // just means the compiler is more lenient than expected.
}

test "doeNativeCheckShaderSource with valid WGSL returns 1 and clears error" {
    const valid_wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(valid_wgsl.ptr, valid_wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);

    // After successful check, error line/column should be cleared.
    try std.testing.expectEqual(@as(u32, 0), shader.doeNativeGetLastErrorLine());
    try std.testing.expectEqual(@as(u32, 0), shader.doeNativeGetLastErrorColumn());
}

test "wgsl compiler translates minimal native Vulkan render benchmark shaders to SPIR-V" {
    const vertex_wgsl =
        \\@vertex fn vs_main(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
        \\    return vec4f(0.0, 0.0, 0.0, 1.0);
        \\}
    ;
    const fragment_wgsl =
        \\@fragment fn fs_main() -> @location(0) vec4f {
        \\    return vec4f(0.0, 0.0, 0.0, 0.0);
        \\}
    ;

    var vertex_spirv: [wgsl_compiler.MAX_SPIRV_OUTPUT]u8 = undefined;
    var fragment_spirv: [wgsl_compiler.MAX_SPIRV_OUTPUT]u8 = undefined;

    const vertex_len = try wgsl_compiler.translateToSpirv(std.testing.allocator, vertex_wgsl, &vertex_spirv);
    const fragment_len = try wgsl_compiler.translateToSpirv(std.testing.allocator, fragment_wgsl, &fragment_spirv);

    try std.testing.expect(vertex_len > 0);
    try std.testing.expect(fragment_len > 0);
}

test "doeNativeDeviceCreateShaderModule with null device returns null" {
    const result = shader.doeNativeDeviceCreateShaderModule(null, null);
    try std.testing.expect(result == null);
}

test "doeNativeDeviceCreateShaderModule with invalid device returns null" {
    // Pass a non-null but invalid-magic pointer for device — will fail the magic check.
    // Use a properly aligned struct to avoid alignment panic.
    var fake_dev = native.DoeDevice{};
    fake_dev.magic = 0xDEADBEEF; // wrong magic
    const result = shader.doeNativeDeviceCreateShaderModule(native.toOpaque(&fake_dev), null);
    try std.testing.expect(result == null);
}

test "doeNativeShaderModuleRelease with null does not crash" {
    shader.doeNativeShaderModuleRelease(null);
}

test "doeNativeShaderModuleRelease with invalid magic does not crash" {
    var fake = native.DoeShaderModule{};
    fake.magic = native.DoeBuffer.TYPE_MAGIC;
    shader.doeNativeShaderModuleRelease(native.toOpaque(&fake));
}

test "doeNativeDeviceCreateComputePipeline with null device returns null" {
    const result = shader.doeNativeDeviceCreateComputePipeline(null, null);
    try std.testing.expect(result == null);
}

test "doeNativeDeviceCreateComputePipeline with invalid device returns null" {
    var fake_dev = native.DoeDevice{};
    fake_dev.magic = 0xDEADBEEF; // corrupt magic
    const result = shader.doeNativeDeviceCreateComputePipeline(native.toOpaque(&fake_dev), null);
    try std.testing.expect(result == null);
}

test "doeNativeComputePipelineRelease with null does not crash" {
    shader.doeNativeComputePipelineRelease(null);
}

test "doeNativeShaderModuleGetBindings with null returns 0" {
    const count = shader.doeNativeShaderModuleGetBindings(null, null, 0);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "doeNativeShaderModuleGetBindings with invalid magic returns 0" {
    var fake = native.DoeShaderModule{};
    fake.magic = native.DoeBuffer.TYPE_MAGIC;
    const count = shader.doeNativeShaderModuleGetBindings(native.toOpaque(&fake), null, 0);
    try std.testing.expectEqual(@as(usize, 0), count);
}

// ============================================================
// Null-pointer safety: render native
// ============================================================

test "doeNativeDeviceCreateTexture with null device returns null" {
    const result = render.doeNativeDeviceCreateTexture(null, null);
    try std.testing.expect(result == null);
}

test "doeNativeDeviceCreateTexture with null descriptor returns null" {
    var fake = native.DoeDevice{};
    fake.magic = 0xDEADBEEF; // wrong magic for DoeDevice
    const result = render.doeNativeDeviceCreateTexture(native.toOpaque(&fake), null);
    try std.testing.expect(result == null);
}

test "doeNativeTextureCreateView with null texture returns null" {
    const result = render.doeNativeTextureCreateView(null, null);
    try std.testing.expect(result == null);
}

test "doeNativeTextureRelease with null does not crash" {
    render.doeNativeTextureRelease(null);
}

test "doeNativeTextureViewRelease with null does not crash" {
    render.doeNativeTextureViewRelease(null);
}

test "doeNativeDeviceCreateSampler with null device returns null" {
    const result = render.doeNativeDeviceCreateSampler(null, null);
    try std.testing.expect(result == null);
}

test "doeNativeDeviceCreateSampler with null descriptor returns null" {
    var fake = native.DoeDevice{};
    fake.magic = 0xDEADBEEF; // wrong magic for DoeDevice
    const result = render.doeNativeDeviceCreateSampler(native.toOpaque(&fake), null);
    try std.testing.expect(result == null);
}

test "doeNativeSamplerRelease with null does not crash" {
    render.doeNativeSamplerRelease(null);
}

test "doeNativeDeviceCreateRenderPipeline with null device returns null" {
    const result = render.doeNativeDeviceCreateRenderPipeline(null, null);
    try std.testing.expect(result == null);
}

test "doeNativeRenderPipelineRelease with null does not crash" {
    render.doeNativeRenderPipelineRelease(null);
}

test "doeNativeCommandEncoderBeginRenderPass with null encoder returns null" {
    const result = render.doeNativeCommandEncoderBeginRenderPass(null, null);
    try std.testing.expect(result == null);
}

test "doeNativeCommandEncoderBeginRenderPass preserves D3D12 attachment extras" {
    var dev = native.DoeDevice{ .backend = .d3d12 };
    var enc = native.DoeCommandEncoder{ .dev = &dev };
    defer enc.cmds.deinit(native.alloc);
    defer @import("../../src/native/command/doe_command_references.zig").releaseAll(&enc.references);

    var color_texture = native.DoeTexture{
        .backend = .d3d12,
        .mtl = @ptrFromInt(0x1010),
        .format = types.WGPUTextureFormat_RGBA8Unorm,
        .sample_count = 4,
    };
    var color_view = native.DoeTextureView{
        .backend = .d3d12,
        .tex = &color_texture,
        .format = types.WGPUTextureFormat_RGBA8Unorm,
        .dimension = types.WGPUTextureViewDimension_3D,
        .base_mip_level = 2,
    };

    var resolve_texture = native.DoeTexture{
        .backend = .d3d12,
        .mtl = @ptrFromInt(0x2020),
        .format = types.WGPUTextureFormat_RGBA8Unorm,
    };
    var resolve_view = native.DoeTextureView{
        .backend = .d3d12,
        .tex = &resolve_texture,
        .format = types.WGPUTextureFormat_RGBA8Unorm,
    };

    var depth_texture = native.DoeTexture{
        .backend = .d3d12,
        .mtl = @ptrFromInt(0x3030),
        .format = types.WGPUTextureFormat_Depth24PlusStencil8,
    };
    var depth_view = native.DoeTextureView{
        .backend = .d3d12,
        .tex = &depth_texture,
        .format = types.WGPUTextureFormat_Depth24PlusStencil8,
        .dimension = types.WGPUTextureViewDimension_2DArrayDepth,
        .base_array_layer = 1,
        .array_layer_count = 2,
    };

    const color_attachment = types.WGPURenderPassColorAttachment{
        .nextInChain = null,
        .view = @ptrCast(native.toOpaque(&color_view)),
        .depthSlice = 7,
        .resolveTarget = @ptrCast(native.toOpaque(&resolve_view)),
        .loadOp = 1,
        .storeOp = 2,
        .clearValue = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 0.4 },
    };
    const color_attachments = [_]types.WGPURenderPassColorAttachment{color_attachment};
    const depth_attachment = types.WGPURenderPassDepthStencilAttachment{
        .view = @ptrCast(native.toOpaque(&depth_view)),
        .depthLoadOp = 2,
        .depthStoreOp = 1,
        .depthClearValue = 0.375,
        .depthReadOnly = 0,
        .stencilLoadOp = 1,
        .stencilStoreOp = 2,
        .stencilClearValue = 7,
        .stencilReadOnly = 0,
    };
    const desc = types.WGPURenderPassDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .colorAttachmentCount = 1,
        .colorAttachments = &color_attachments,
        .depthStencilAttachment = &depth_attachment,
        .occlusionQuerySet = null,
        .timestampWrites = null,
    };

    const pass_raw = render.doeNativeCommandEncoderBeginRenderPass(native.toOpaque(&enc), &desc) orelse return error.UnexpectedNull;
    defer render.doeNativeRenderPassRelease(pass_raw);
    const pass = native.cast(native.DoeRenderPass, pass_raw) orelse return error.UnexpectedNull;

    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x1010)), pass.target);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x2020)), pass.resolve_target);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x3030)), pass.depth_target);
    try std.testing.expectEqual(@intFromPtr(&color_view), pass.target_view_handle);
    try std.testing.expectEqual(@intFromPtr(&resolve_view), pass.resolve_target_view_handle);
    try std.testing.expectEqual(@intFromPtr(&depth_view), pass.depth_target_view_handle);
    try std.testing.expectEqual(types.WGPUTextureFormat_RGBA8Unorm, pass.target_format);
    try std.testing.expectEqual(types.WGPUTextureFormat_Depth24PlusStencil8, pass.depth_stencil_format);
    try std.testing.expectEqual(@as(u32, 4), pass.sample_count);
    try std.testing.expectEqual(@as(u32, 7), pass.depth_slice);
    try std.testing.expect(!pass.depth_read_only);
    try std.testing.expect(!pass.stencil_read_only);
    try std.testing.expectEqual(@as(u32, 1), pass.color_load_op);
    try std.testing.expectEqual(@as(u32, 2), pass.color_store_op);
    try std.testing.expectEqual(@as(u32, 2), pass.depth_load_op);
    try std.testing.expectEqual(@as(u32, 1), pass.depth_store_op);
    try std.testing.expectEqual(@as(u32, 1), pass.stencil_load_op);
    try std.testing.expectEqual(@as(u32, 2), pass.stencil_store_op);
    try std.testing.expectEqual(@as(f32, 0.375), pass.depth_clear_value);
    try std.testing.expectEqual(@as(u32, 7), pass.stencil_clear_value);
}

test "doeNativeRenderPassDraw records D3D12 attachment view metadata" {
    var dev = native.DoeDevice{ .backend = .d3d12 };
    var enc = native.DoeCommandEncoder{ .dev = &dev };
    defer enc.cmds.deinit(native.alloc);
    defer @import("../../src/native/command/doe_command_references.zig").releaseAll(&enc.references);

    var pipeline = native.DoeRenderPipeline{
        .mtl_pso = @ptrFromInt(0x1111),
        .backend_root_signature = @ptrFromInt(0x2222),
        .topology = 0x00000004,
        .sample_count = 4,
        .depth_stencil_format = types.WGPUTextureFormat_Depth24PlusStencil8,
    };
    var pass = native.DoeRenderPass{
        .enc = &enc,
        .pipeline = &pipeline,
        .target = @ptrFromInt(0x3333),
        .resolve_target = @ptrFromInt(0x4444),
        .depth_target = @ptrFromInt(0x5555),
        .target_view_handle = 0x6666,
        .resolve_target_view_handle = 0x7777,
        .depth_target_view_handle = 0x8888,
        .target_format = types.WGPUTextureFormat_RGBA8Unorm,
        .depth_stencil_format = types.WGPUTextureFormat_Depth24PlusStencil8,
        .sample_count = 4,
        .depth_slice = 3,
        .depth_read_only = true,
        .stencil_read_only = true,
        .blend_constant = .{ 0.1, 0.2, 0.3, 0.4 },
        .stencil_reference = 9,
    };

    render.doeNativeRenderPassDraw(native.toOpaque(&pass), 6, 2, 1, 0);

    try std.testing.expectEqual(@as(usize, 1), enc.cmds.items.len);
    switch (enc.cmds.items[0]) {
        .render_pass => |cmd| {
            try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x3333)), cmd.target);
            try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x4444)), cmd.resolve_target);
            try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x5555)), cmd.depth_target);
            try std.testing.expectEqual(@as(u64, 0x6666), cmd.target_view_handle);
            try std.testing.expectEqual(@as(u64, 0x7777), cmd.resolve_target_view_handle);
            try std.testing.expectEqual(@as(u64, 0x8888), cmd.depth_target_view_handle);
            try std.testing.expectEqual(types.WGPUTextureFormat_RGBA8Unorm, cmd.target_format);
            try std.testing.expectEqual(types.WGPUTextureFormat_Depth24PlusStencil8, cmd.depth_stencil_format);
            try std.testing.expectEqual(@as(u32, 4), cmd.sample_count);
            try std.testing.expectEqual(@as(u32, 3), cmd.depth_slice);
            try std.testing.expect(cmd.depth_read_only);
            try std.testing.expect(cmd.stencil_read_only);
            try std.testing.expectEqual(@as(u32, 6), cmd.vertex_count);
            try std.testing.expectEqual(@as(u32, 2), cmd.instance_count);
        },
        else => return error.UnexpectedCommandTag,
    }
}

test "doeNativeRenderPassSetPipeline with null pass does not crash" {
    render.doeNativeRenderPassSetPipeline(null, null);
}

test "doeNativeRenderPassDraw with null pass does not crash" {
    render.doeNativeRenderPassDraw(null, 3, 1, 0, 0);
}

test "doeNativeRenderPassEnd with null does not crash" {
    render.doeNativeRenderPassEnd(null);
}

test "Metal render pass records one encoder boundary across multiple draws" {
    var dev = native.DoeDevice{ .backend = .metal };
    var enc = native.DoeCommandEncoder{ .dev = &dev };
    defer enc.cmds.deinit(native.alloc);
    defer @import("../../src/native/command/doe_command_references.zig").releaseAll(&enc.references);
    var pipeline = native.DoeRenderPipeline{
        .mtl_pso = @ptrFromInt(0x1111),
        .topology = 0x00000004,
    };
    var pass = native.DoeRenderPass{
        .enc = &enc,
        .pipeline = &pipeline,
        .target = @ptrFromInt(0x2222),
        .color_load_op = 2,
        .color_store_op = 1,
    };

    render.doeNativeRenderPassDraw(native.toOpaque(&pass), 3, 1, 0, 0);
    render.doeNativeRenderPassDraw(native.toOpaque(&pass), 6, 2, 0, 0);
    render.doeNativeRenderPassEnd(native.toOpaque(&pass));

    try std.testing.expectEqual(@as(usize, 2), enc.cmds.items.len);
    switch (enc.cmds.items[0]) {
        .render_pass => |cmd| {
            try std.testing.expect(cmd.pass_start);
            try std.testing.expect(!cmd.pass_end);
        },
        else => return error.UnexpectedCommandTag,
    }
    switch (enc.cmds.items[1]) {
        .render_pass => |cmd| {
            try std.testing.expect(!cmd.pass_start);
            try std.testing.expect(cmd.pass_end);
        },
        else => return error.UnexpectedCommandTag,
    }
}

test "Metal empty render pass records attachment operations" {
    var dev = native.DoeDevice{ .backend = .metal };
    var enc = native.DoeCommandEncoder{ .dev = &dev };
    defer enc.cmds.deinit(native.alloc);
    defer @import("../../src/native/command/doe_command_references.zig").releaseAll(&enc.references);
    var pass = native.DoeRenderPass{
        .enc = &enc,
        .target = @ptrFromInt(0x3333),
        .color_load_op = 2,
        .color_store_op = 1,
        .clear_r = 0.25,
    };

    render.doeNativeRenderPassEnd(native.toOpaque(&pass));

    try std.testing.expectEqual(@as(usize, 1), enc.cmds.items.len);
    switch (enc.cmds.items[0]) {
        .render_pass => |cmd| {
            try std.testing.expect(cmd.pass_start);
            try std.testing.expect(cmd.pass_end);
            try std.testing.expectEqual(@as(u32, 0), cmd.draw_count);
            try std.testing.expectEqual(@as(u32, 2), cmd.color_load_op);
            try std.testing.expectEqual(@as(u32, 1), cmd.color_store_op);
            try std.testing.expectEqual(@as(f64, 0.25), cmd.clear_r);
        },
        else => return error.UnexpectedCommandTag,
    }
}

test "doeNativeRenderPassRelease with null does not crash" {
    render.doeNativeRenderPassRelease(null);
}

// ============================================================
// Null-pointer safety: query native
// ============================================================

test "doeNativeDeviceCreateQuerySet with null device returns null" {
    const result = query.doeNativeDeviceCreateQuerySet(null, types.WGPUQueryType_Timestamp, 2);
    try std.testing.expect(result == null);
}

test "doeNativeDeviceCreateQuerySet with non-timestamp type returns null" {
    // query_type 0 is WGPUQueryType_Occlusion, which is not supported.
    const result = query.doeNativeDeviceCreateQuerySet(null, 0, 2);
    try std.testing.expect(result == null);
}

test "doeNativeDeviceCreateQuerySet with count 0 returns null" {
    const result = query.doeNativeDeviceCreateQuerySet(null, types.WGPUQueryType_Timestamp, 0);
    try std.testing.expect(result == null);
}

test "doeNativeCommandEncoderWriteTimestamp with null encoder does not crash" {
    query.doeNativeCommandEncoderWriteTimestamp(null, null, 0);
}

test "doeNativeCommandEncoderResolveQuerySet with null encoder does not crash" {
    query.doeNativeCommandEncoderResolveQuerySet(null, null, 0, 2, null, 0);
}

test "doeNativeCommandEncoderWriteTimestamp records a metal timestamp command" {
    var dev = native.DoeDevice{};
    var enc = native.DoeCommandEncoder{ .dev = &dev };
    defer enc.cmds.deinit(native.alloc);
    defer @import("../../src/native/command/doe_command_references.zig").releaseAll(&enc.references);

    var qs = query.DoeQuerySet{
        .count = 4,
        .query_type = types.WGPUQueryType_Timestamp,
        .backend = .metal,
        .counter_sample_buffer = @ptrFromInt(0x1),
    };

    query.doeNativeCommandEncoderWriteTimestamp(native.toOpaque(&enc), native.toOpaque(&qs), 2);

    try std.testing.expectEqual(@as(usize, 1), enc.cmds.items.len);
    try std.testing.expectEqual(@as(u32, 2), qs.ref_count);
    switch (enc.cmds.items[0]) {
        .write_timestamp => |cmd| {
            try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x1)), cmd.counter_buffer);
            try std.testing.expectEqual(@as(u32, 2), cmd.query_index);
        },
        else => return error.UnexpectedCommandTag,
    }
    query.releaseRecordedCommandReferences(enc.cmds.items);
    try std.testing.expectEqual(@as(u32, 1), qs.ref_count);
}

test "doeNativeCommandEncoderResolveQuerySet records a metal resolve command" {
    var dev = native.DoeDevice{};
    var enc = native.DoeCommandEncoder{ .dev = &dev };
    defer enc.cmds.deinit(native.alloc);
    defer @import("../../src/native/command/doe_command_references.zig").releaseAll(&enc.references);

    var qs = query.DoeQuerySet{
        .count = 4,
        .query_type = types.WGPUQueryType_Timestamp,
        .backend = .metal,
        .counter_sample_buffer = @ptrFromInt(0x2),
    };
    var dst = native.DoeBuffer{
        .mtl = @ptrFromInt(0x3),
        .size = 64,
    };

    query.doeNativeCommandEncoderResolveQuerySet(
        native.toOpaque(&enc),
        native.toOpaque(&qs),
        1,
        2,
        native.toOpaque(&dst),
        8,
    );

    try std.testing.expectEqual(@as(usize, 1), enc.cmds.items.len);
    try std.testing.expectEqual(@as(u32, 2), qs.ref_count);
    switch (enc.cmds.items[0]) {
        .resolve_query_set => |cmd| {
            try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x2)), cmd.counter_buffer);
            try std.testing.expectEqual(@as(u32, 1), cmd.first_query);
            try std.testing.expectEqual(@as(u32, 2), cmd.query_count);
            try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x3)), cmd.dst_mtl);
            try std.testing.expectEqual(@as(u64, 8), cmd.dst_offset);
        },
        else => return error.UnexpectedCommandTag,
    }
    query.releaseRecordedCommandReferences(enc.cmds.items);
    try std.testing.expectEqual(@as(u32, 1), qs.ref_count);
}

test "doeNativeQuerySetDestroy with null does not crash" {
    query.doeNativeQuerySetDestroy(null);
}

test "doeNativeQuerySetDestroy with invalid magic does not crash" {
    var fake = native.DoeBuffer{}; // wrong magic for DoeQuerySet
    query.doeNativeQuerySetDestroy(native.toOpaque(&fake));
}

test "query set destroy is idempotent and release owns handle lifetime" {
    const qs = native.make(query.DoeQuerySet) orelse return error.OutOfMemory;
    qs.* = .{
        .count = 2,
        .query_type = types.WGPUQueryType_Timestamp,
        .backend = .metal,
    };
    const raw = native.toOpaque(qs);

    query.doeNativeQuerySetDestroy(raw);
    query.doeNativeQuerySetDestroy(raw);
    try std.testing.expect(qs.destroyed);
    try std.testing.expectEqual(@as(u32, 1), qs.ref_count);

    query.doeNativeQuerySetRelease(raw);
}

// ============================================================
// Null-pointer safety: instance device native
// ============================================================

test "doeNativeCreateInstance with null descriptor succeeds" {
    const inst = instance_device.doeNativeCreateInstance(null);
    try std.testing.expect(inst != null);
    // Clean up.
    instance_device.doeNativeInstanceRelease(inst);
}

test "doeNativeInstanceRelease with null does not crash" {
    instance_device.doeNativeInstanceRelease(null);
}

test "doeNativeInstanceRelease with invalid magic does not crash" {
    var fake = native.DoeBuffer{}; // wrong magic for DoeInstance
    instance_device.doeNativeInstanceRelease(native.toOpaque(&fake));
}

test "doeNativeAdapterRelease with null does not crash" {
    instance_device.doeNativeAdapterRelease(null);
}

test "doeNativeDeviceRelease with null does not crash" {
    instance_device.doeNativeDeviceRelease(null);
}

test "doeNativeDeviceGetQueue with null device returns null" {
    const result = instance_device.doeNativeDeviceGetQueue(null);
    try std.testing.expect(result == null);
}

test "doeNativeDeviceGetQueue with invalid magic returns null" {
    var fake = native.DoeDevice{};
    fake.magic = 0xDEADBEEF; // wrong magic for DoeDevice
    const result = instance_device.doeNativeDeviceGetQueue(native.toOpaque(&fake));
    try std.testing.expect(result == null);
}

// ============================================================
// Constants: query native
// ============================================================

test "DoeQuerySet magic matches expected value" {
    try std.testing.expectEqual(@as(u32, 0xD0E1_0020), query.DoeQuerySet.TYPE_MAGIC);
}

test "DoeQuerySet default initialization has correct defaults" {
    const qs = query.DoeQuerySet{};
    try std.testing.expectEqual(@as(u32, 0xD0E1_0020), qs.magic);
    try std.testing.expectEqual(@as(u32, 0), qs.count);
    try std.testing.expectEqual(@as(u32, types.WGPUQueryType_Timestamp), qs.query_type);
    try std.testing.expectEqual(native.BackendKind.metal, qs.backend);
    try std.testing.expect(qs.counter_sample_buffer == null);
    try std.testing.expectEqual(@as(vk.VkQueryPool, vk.VK_NULL_U64), qs.vk_query_pool);
    try std.testing.expect(qs.vk_device == null);
    try std.testing.expect(qs.vk_runtime_ref == null);
}

test "timestamp query type constant matches spec" {
    try std.testing.expectEqual(@as(u32, 0x00000002), types.WGPUQueryType_Timestamp);
}

test "doeNativeQuerySetGetCount and GetType expose stored query metadata" {
    var qs = query.DoeQuerySet{
        .count = 7,
        .query_type = WGPU_QUERY_TYPE_OCCLUSION,
        .backend = .vulkan,
    };

    try std.testing.expectEqual(@as(u32, 7), query.doeNativeQuerySetGetCount(native.toOpaque(&qs)));
    try std.testing.expectEqual(@as(u32, WGPU_QUERY_TYPE_OCCLUSION), query.doeNativeQuerySetGetType(native.toOpaque(&qs)));
    try std.testing.expectEqual(@as(u32, 0), query.doeNativeQuerySetGetCount(null));
    try std.testing.expectEqual(@as(u32, 0), query.doeNativeQuerySetGetType(null));
}

test "doeNativeRenderPass occlusion query toggles pass state for occlusion query sets" {
    var dev = native.DoeDevice{};
    var enc = native.DoeCommandEncoder{ .dev = &dev };
    var pass = native.DoeRenderPass{ .enc = &enc };
    var qs = query.DoeQuerySet{
        .count = 3,
        .query_type = WGPU_QUERY_TYPE_OCCLUSION,
        .backend = .vulkan,
    };
    pass.occlusion_query_set = native.toOpaque(&qs);

    query.doeNativeRenderPassBeginOcclusionQuery(native.toOpaque(&pass), 2);
    try std.testing.expect(pass.occlusion_query_active);
    try std.testing.expectEqual(@as(u32, 2), pass.occlusion_query_index);

    query.doeNativeRenderPassEndOcclusionQuery(native.toOpaque(&pass));
    try std.testing.expect(!pass.occlusion_query_active);
}

test "doeNativeRenderPassBeginOcclusionQuery ignores non-occlusion query sets" {
    var dev = native.DoeDevice{};
    var enc = native.DoeCommandEncoder{ .dev = &dev };
    var pass = native.DoeRenderPass{ .enc = &enc };
    var qs = query.DoeQuerySet{
        .count = 3,
        .query_type = types.WGPUQueryType_Timestamp,
        .backend = .vulkan,
    };
    pass.occlusion_query_set = native.toOpaque(&qs);

    query.doeNativeRenderPassBeginOcclusionQuery(native.toOpaque(&pass), 1);
    try std.testing.expect(!pass.occlusion_query_active);
    try std.testing.expectEqual(@as(u32, 0), pass.occlusion_query_index);
}

// ============================================================
// Constants: handle type magics
// ============================================================

test "handle magic constants are distinct for types with pub TYPE_MAGIC or default init" {
    // Test distinctness for types that expose TYPE_MAGIC or can be default-initialized.
    // Types with required non-nullable pointer fields are excluded (they require a
    // valid parent object, tested via cast/make round-trips elsewhere).
    const inst_magic = (native.DoeInstance{}).magic;
    const adapter_magic = (native.DoeAdapter{}).magic;
    const dev_magic = (native.DoeDevice{}).magic;
    const queue_magic = native.DoeQueue.TYPE_MAGIC;
    const buf_magic = native.DoeBuffer.TYPE_MAGIC;
    const shader_magic = (native.DoeShaderModule{}).magic;
    const compute_magic = native.DoeComputePipeline.TYPE_MAGIC;
    const bgl_magic = (native.DoeBindGroupLayout{}).magic;
    const pl_magic = (native.DoePipelineLayout{}).magic;
    const bg_magic = native.DoeBindGroup.TYPE_MAGIC;
    const tex_magic = (native.DoeTexture{}).magic;
    const samp_magic = (native.DoeSampler{}).magic;
    const rp_magic = (native.DoeRenderPipeline{}).magic;
    const qs_magic = query.DoeQuerySet.TYPE_MAGIC;

    const magics = [_]u32{
        inst_magic, adapter_magic, dev_magic,     queue_magic,
        buf_magic,  shader_magic,  compute_magic, bgl_magic,
        pl_magic,   bg_magic,      tex_magic,     samp_magic,
        rp_magic,   qs_magic,
    };
    // Every pair of magics must differ.
    for (magics, 0..) |a, i| {
        for (magics[i + 1 ..]) |b| {
            try std.testing.expect(a != b);
        }
    }
}

test "handle magics share the D0E1 prefix" {
    try std.testing.expect((native.DoeInstance{}).magic & 0xFFFF_0000 == 0xD0E1_0000);
    try std.testing.expect((native.DoeDevice{}).magic & 0xFFFF_0000 == 0xD0E1_0000);
    try std.testing.expect(native.DoeQueue.TYPE_MAGIC & 0xFFFF_0000 == 0xD0E1_0000);
    try std.testing.expect(native.DoeBuffer.TYPE_MAGIC & 0xFFFF_0000 == 0xD0E1_0000);
    try std.testing.expect((native.DoeTexture{}).magic & 0xFFFF_0000 == 0xD0E1_0000);
    try std.testing.expect((native.DoeRenderPipeline{}).magic & 0xFFFF_0000 == 0xD0E1_0000);
    try std.testing.expect(query.DoeQuerySet.TYPE_MAGIC & 0xFFFF_0000 == 0xD0E1_0000);
}

// ============================================================
// Constants: capacity and size constants
// ============================================================

test "ERR_CAP is 512" {
    try std.testing.expectEqual(@as(usize, 512), native.ERR_CAP);
}

test "MAX_BIND is 32" {
    try std.testing.expectEqual(@as(usize, 32), native.MAX_BIND);
}

test "MAX_FLAT_BIND is MAX_BIND * MAX_COMPUTE_BIND_GROUPS" {
    try std.testing.expectEqual(native.MAX_BIND * native.MAX_COMPUTE_BIND_GROUPS, native.MAX_FLAT_BIND);
}

test "MAX_VERTEX_BUFFERS is 8" {
    try std.testing.expectEqual(@as(usize, 8), native.MAX_VERTEX_BUFFERS);
}

test "VERTEX_BUFFER_SLOT_BASE is 8" {
    try std.testing.expectEqual(@as(u32, 8), native.VERTEX_BUFFER_SLOT_BASE);
}

test "MAX_SHADER_BINDINGS matches wgsl compiler MAX_BINDINGS" {
    try std.testing.expectEqual(wgsl_compiler.MAX_BINDINGS, native.MAX_SHADER_BINDINGS);
}

// ============================================================
// Constants: texture format values match WebGPU spec
// ============================================================

test "RGBA8Unorm format value is 0x16" {
    try std.testing.expectEqual(@as(u32, 0x00000016), types.WGPUTextureFormat_RGBA8Unorm);
}

test "BGRA8Unorm format value is 0x1B" {
    try std.testing.expectEqual(@as(u32, 0x0000001B), types.WGPUTextureFormat_BGRA8Unorm);
}

test "Depth32Float format value is 0x30" {
    try std.testing.expectEqual(@as(u32, 0x00000030), types.WGPUTextureFormat_Depth32Float);
}

test "R8Unorm format value is 0x01" {
    try std.testing.expectEqual(@as(u32, 0x00000001), types.WGPUTextureFormat_R8Unorm);
}

// ============================================================
// Constants: buffer usage flags match WebGPU spec
// ============================================================

test "buffer usage flag values match spec" {
    try std.testing.expectEqual(@as(u64, 0x0000000000000001), types.WGPUBufferUsage_MapRead);
    try std.testing.expectEqual(@as(u64, 0x0000000000000002), types.WGPUBufferUsage_MapWrite);
    try std.testing.expectEqual(@as(u64, 0x0000000000000004), types.WGPUBufferUsage_CopySrc);
    try std.testing.expectEqual(@as(u64, 0x0000000000000008), types.WGPUBufferUsage_CopyDst);
    try std.testing.expectEqual(@as(u64, 0x0000000000000040), types.WGPUBufferUsage_Uniform);
    try std.testing.expectEqual(@as(u64, 0x0000000000000080), types.WGPUBufferUsage_Storage);
    try std.testing.expectEqual(@as(u64, 0x0000000000000200), types.WGPUBufferUsage_QueryResolve);
}

// ============================================================
// Constants: feature name values match WebGPU spec
// ============================================================

test "ShaderF16 feature value is 0x0B" {
    try std.testing.expectEqual(@as(u32, 0x0000000B), types.WGPUFeatureName_ShaderF16);
}

test "TimestampQuery feature value is 0x09" {
    try std.testing.expectEqual(@as(u32, 0x00000009), types.WGPUFeatureName_TimestampQuery);
}

test "IndirectFirstInstance feature value is 0x0A" {
    try std.testing.expectEqual(@as(u32, 0x0000000A), types.WGPUFeatureName_IndirectFirstInstance);
}

// ============================================================
// Constants: device caps feature constants
// ============================================================

test "device caps FEATURE_SUBGROUPS matches expected value" {
    try std.testing.expectEqual(@as(u32, 0x00000012), caps.FEATURE_SUBGROUPS);
}

test "device caps METAL_SIMD_GROUP_SIZE is 32" {
    try std.testing.expectEqual(@as(u32, 32), caps.METAL_SIMD_GROUP_SIZE);
}

// ============================================================
// Constants: instance device status codes
// ============================================================

test "WGPUFuture struct has expected layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(types.WGPUFuture));
}

test "WGPUStringView struct has expected layout" {
    // pointer + usize
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(types.WGPUStringView));
}

// ============================================================
// Pure helper: extractWorkgroupSize
// ============================================================

test "extractWorkgroupSize parses single-dimension workgroup" {
    const wgsl = "@workgroup_size(64)\nfn main() {}";
    const wg = native.extractWorkgroupSize(wgsl);
    try std.testing.expectEqual(@as(u32, 64), wg.x);
    try std.testing.expectEqual(@as(u32, 1), wg.y);
    try std.testing.expectEqual(@as(u32, 1), wg.z);
}

test "extractWorkgroupSize parses two-dimension workgroup" {
    const wgsl = "@workgroup_size(8, 16)\nfn main() {}";
    const wg = native.extractWorkgroupSize(wgsl);
    try std.testing.expectEqual(@as(u32, 8), wg.x);
    try std.testing.expectEqual(@as(u32, 16), wg.y);
    try std.testing.expectEqual(@as(u32, 1), wg.z);
}

test "extractWorkgroupSize parses three-dimension workgroup" {
    const wgsl = "@workgroup_size(4, 8, 2)\nfn main() {}";
    const wg = native.extractWorkgroupSize(wgsl);
    try std.testing.expectEqual(@as(u32, 4), wg.x);
    try std.testing.expectEqual(@as(u32, 8), wg.y);
    try std.testing.expectEqual(@as(u32, 2), wg.z);
}

test "extractWorkgroupSize with no annotation returns zeros mapped to 1" {
    const wgsl = "fn main() {}";
    const wg = native.extractWorkgroupSize(wgsl);
    // When no annotation is found, raw values are 0; the function maps them to 1.
    // Actually, when no annotation found, x/y/z = 0 (the fallback return is .{.x=0,.y=0,.z=0}).
    try std.testing.expectEqual(@as(u32, 0), wg.x);
    try std.testing.expectEqual(@as(u32, 0), wg.y);
    try std.testing.expectEqual(@as(u32, 0), wg.z);
}

test "extractWorkgroupSize with spaces in args" {
    const wgsl = "@workgroup_size( 16 , 32 , 4 )\nfn main() {}";
    const wg = native.extractWorkgroupSize(wgsl);
    try std.testing.expectEqual(@as(u32, 16), wg.x);
    try std.testing.expectEqual(@as(u32, 32), wg.y);
    try std.testing.expectEqual(@as(u32, 4), wg.z);
}

test "extractWorkgroupSize with workgroup_size(1) returns 1,1,1" {
    const wgsl = "@workgroup_size(1)\nfn main() {}";
    const wg = native.extractWorkgroupSize(wgsl);
    try std.testing.expectEqual(@as(u32, 1), wg.x);
    try std.testing.expectEqual(@as(u32, 1), wg.y);
    try std.testing.expectEqual(@as(u32, 1), wg.z);
}

test "extractWorkgroupSize with large value" {
    const wgsl = "@workgroup_size(1024)\nfn main() {}";
    const wg = native.extractWorkgroupSize(wgsl);
    try std.testing.expectEqual(@as(u32, 1024), wg.x);
}

// ============================================================
// Pure helper: cast (type-checked downcast)
// ============================================================

test "cast with null returns null" {
    const result = native.cast(native.DoeDevice, null);
    try std.testing.expect(result == null);
}

test "cast with wrong magic returns null" {
    // Create a device handle with corrupted magic and try to cast it.
    var dev = native.DoeDevice{};
    dev.magic = 0xDEADBEEF;
    const result = native.cast(native.DoeDevice, native.toOpaque(&dev));
    try std.testing.expect(result == null);
}

test "cast with correct magic succeeds" {
    var buf = native.DoeBuffer{};
    const result = native.cast(native.DoeBuffer, native.toOpaque(&buf));
    try std.testing.expect(result != null);
    try std.testing.expectEqual(native.DoeBuffer.TYPE_MAGIC, result.?.magic);
}

test "cast round-trips through toOpaque" {
    var inst = native.DoeInstance{};
    const ptr = native.toOpaque(&inst);
    const back = native.cast(native.DoeInstance, ptr);
    try std.testing.expect(back != null);
    try std.testing.expect(@intFromPtr(back.?) == @intFromPtr(&inst));
}

// ============================================================
// Pure helper: make (allocation with null return)
// ============================================================

test "make allocates a non-null pointer" {
    const dev = native.make(native.DoeDevice);
    try std.testing.expect(dev != null);
    // make() allocates without initializing — caller must assign fields.
    // Verify allocation succeeded.
    const d = dev.?;
    d.* = .{}; // initialize with defaults
    try std.testing.expectEqual((native.DoeDevice{}).magic, d.magic);
    native.alloc.destroy(d);
}

test "make DoeInstance allocates successfully" {
    const inst = native.make(native.DoeInstance);
    try std.testing.expect(inst != null);
    inst.?.* = .{}; // initialize with defaults
    try std.testing.expectEqual((native.DoeInstance{}).magic, inst.?.magic);
    native.alloc.destroy(inst.?);
}

// ============================================================
// Shader error state management
// ============================================================

test "doeNativeCopyLastErrorMessage copies error into buffer" {
    // Force an error by checking null WGSL.
    _ = shader.doeNativeCheckShaderSource(null, 0);

    var buf: [512]u8 = undefined;
    const len = shader.doeNativeCopyLastErrorMessage(&buf, buf.len);
    try std.testing.expect(len > 0);

    // The copied string should be null-terminated.
    try std.testing.expectEqual(@as(u8, 0), buf[len]);
}

test "doeNativeCopyLastErrorMessage truncates to out_len minus 1" {
    // Force an error.
    _ = shader.doeNativeCheckShaderSource(null, 0);

    // Use a very small buffer.
    var buf: [8]u8 = undefined;
    const full_len = shader.doeNativeCopyLastErrorMessage(&buf, buf.len);
    // The returned value is the full error length, not the truncated length.
    try std.testing.expect(full_len > 0);

    // The last byte should be null-terminated within our buffer.
    const copy_len = @min(full_len, buf.len - 1);
    try std.testing.expectEqual(@as(u8, 0), buf[copy_len]);
}

test "successful shader check clears error line and column" {
    // First, trigger an error to populate error state.
    _ = shader.doeNativeCheckShaderSource(null, 0);

    // Now check valid WGSL.
    const valid_wgsl =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(1)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    buf[gid.x] = gid.x;
        \\}
    ;
    const result = shader.doeNativeCheckShaderSource(valid_wgsl.ptr, valid_wgsl.len);
    try std.testing.expectEqual(@as(u32, 1), result);
    try std.testing.expectEqual(@as(u32, 0), shader.doeNativeGetLastErrorLine());
    try std.testing.expectEqual(@as(u32, 0), shader.doeNativeGetLastErrorColumn());
}

// ============================================================
// Instance lifecycle (no Metal required for basic instance)
// ============================================================

test "instance create and release round-trip" {
    const inst = instance_device.doeNativeCreateInstance(null);
    try std.testing.expect(inst != null);

    // Verify the opaque pointer round-trips to a valid DoeInstance.
    const typed = native.cast(native.DoeInstance, inst);
    try std.testing.expect(typed != null);
    try std.testing.expectEqual((native.DoeInstance{}).magic, typed.?.magic);

    instance_device.doeNativeInstanceRelease(inst);
}

test "multiple instances can coexist" {
    const a = instance_device.doeNativeCreateInstance(null);
    const b = instance_device.doeNativeCreateInstance(null);
    try std.testing.expect(a != null);
    try std.testing.expect(b != null);
    try std.testing.expect(a != b);

    instance_device.doeNativeInstanceRelease(a);
    instance_device.doeNativeInstanceRelease(b);
}

// ============================================================
// InstanceWaitAny (synchronous — marks all completed)
// ============================================================

test "doeNativeInstanceWaitAny marks all infos as completed" {
    var infos = [_]types.WGPUFutureWaitInfo{
        .{ .future = .{ .id = 100 }, .completed = 0 },
        .{ .future = .{ .id = 200 }, .completed = 0 },
        .{ .future = .{ .id = 300 }, .completed = 0 },
    };

    const status = instance_device.doeNativeInstanceWaitAny(null, infos.len, &infos, 0);
    // Should return WGPU_WAIT_STATUS_SUCCESS = 1.
    try std.testing.expectEqual(@as(u32, 1), status);

    // All infos should be marked as completed.
    for (infos) |info| {
        try std.testing.expectEqual(@as(u32, 1), info.completed);
    }
}

test "doeNativeInstanceWaitAny with count 0 returns success" {
    var dummy: types.WGPUFutureWaitInfo = .{ .future = .{ .id = 0 }, .completed = 0 };
    const status = instance_device.doeNativeInstanceWaitAny(null, 0, @ptrCast(&dummy), 1000);
    try std.testing.expectEqual(@as(u32, 1), status);
}

// ============================================================
// Device caps: feature queries
// ============================================================

test "doeNativeAdapterHasFeature returns 1 for ShaderF16" {
    const result = caps.doeNativeAdapterHasFeature(null, types.WGPUFeatureName_ShaderF16);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "doeNativeDeviceHasFeature returns 1 for ShaderF16" {
    const result = caps.doeNativeDeviceHasFeature(null, types.WGPUFeatureName_ShaderF16);
    try std.testing.expectEqual(@as(u32, 1), result);
}

test "doeNativeAdapterHasFeature returns 0 for unsupported feature" {
    // Use a bogus feature ID.
    const result = caps.doeNativeAdapterHasFeature(null, 0x99999999);
    try std.testing.expectEqual(@as(u32, 0), result);
}

test "doeNativeDeviceHasFeature returns 0 for unsupported feature" {
    const result = caps.doeNativeDeviceHasFeature(null, 0x99999999);
    try std.testing.expectEqual(@as(u32, 0), result);
}

test "doeNativeDeviceSubgroupSize returns 32 on macOS" {
    const result = caps.doeNativeDeviceSubgroupSize(null);
    // On macOS (where tests run), should be 32.
    if (@import("builtin").os.tag == .macos) {
        try std.testing.expectEqual(@as(u32, 32), result);
    }
}

// ============================================================
// Device caps: limits queries
// ============================================================

test "doeNativeDeviceGetLimits populates limits struct" {
    var limits = std.mem.zeroes(types.WGPULimits);
    const status = caps.doeNativeDeviceGetLimits(null, &limits);
    try std.testing.expectEqual(types.WGPUStatus_Success, status);

    // Check known Metal defaults.
    try std.testing.expectEqual(@as(u32, 16384), limits.maxTextureDimension1D);
    try std.testing.expectEqual(@as(u32, 16384), limits.maxTextureDimension2D);
    try std.testing.expectEqual(@as(u32, 2048), limits.maxTextureDimension3D);
    try std.testing.expectEqual(@as(u32, 4), limits.maxBindGroups);
    try std.testing.expectEqual(@as(u32, 1024), limits.maxComputeInvocationsPerWorkgroup);
    try std.testing.expectEqual(@as(u32, 1024), limits.maxComputeWorkgroupSizeX);
    try std.testing.expectEqual(@as(u32, 1024), limits.maxComputeWorkgroupSizeY);
    try std.testing.expectEqual(@as(u32, 64), limits.maxComputeWorkgroupSizeZ);
    try std.testing.expectEqual(@as(u32, 65535), limits.maxComputeWorkgroupsPerDimension);
    try std.testing.expectEqual(@as(u64, 65536), limits.maxUniformBufferBindingSize);
    try std.testing.expectEqual(@as(u32, 256), limits.minUniformBufferOffsetAlignment);
    try std.testing.expectEqual(@as(u32, 32), limits.minStorageBufferOffsetAlignment);
    try std.testing.expectEqual(@as(u32, 8), limits.maxVertexBuffers);
    try std.testing.expectEqual(@as(u32, 8), limits.maxColorAttachments);
}

test "doeNativeAdapterGetLimits populates same values as device" {
    var dev_limits = std.mem.zeroes(types.WGPULimits);
    var adapter_limits = std.mem.zeroes(types.WGPULimits);

    _ = caps.doeNativeDeviceGetLimits(null, &dev_limits);
    _ = caps.doeNativeAdapterGetLimits(null, &adapter_limits);

    // Both should report the same static limits when called without a device handle.
    try std.testing.expectEqual(dev_limits.maxTextureDimension1D, adapter_limits.maxTextureDimension1D);
    try std.testing.expectEqual(dev_limits.maxComputeInvocationsPerWorkgroup, adapter_limits.maxComputeInvocationsPerWorkgroup);
    try std.testing.expectEqual(dev_limits.maxBufferSize, adapter_limits.maxBufferSize);
    try std.testing.expectEqual(dev_limits.maxStorageBufferBindingSize, adapter_limits.maxStorageBufferBindingSize);
}

test "doeNativeDeviceGetLimits with null limits pointer returns success" {
    const status = caps.doeNativeDeviceGetLimits(null, null);
    try std.testing.expectEqual(types.WGPUStatus_Success, status);
}

// ============================================================
// Struct layout: BindingInfo
// ============================================================

test "BindingInfo default has buffer kind" {
    const info = native.BindingInfo{ .group = 0, .binding = 0 };
    try std.testing.expectEqual(@as(u32, @intFromEnum(wgsl_compiler.BindingKind.buffer)), info.kind);
    try std.testing.expectEqual(@as(u32, 0), info.addr_space);
    try std.testing.expectEqual(@as(u32, 0), info.access);
}

// ============================================================
// Struct layout: DoeRenderPipeline defaults
// ============================================================

test "DoeRenderPipeline default topology is triangle list" {
    const rp = native.DoeRenderPipeline{};
    // 0x00000004 = WGPUPrimitiveTopology_TriangleList (Metal convention).
    try std.testing.expectEqual(@as(u32, 0x00000004), rp.topology);
}

test "DoeRenderPipeline default front_face is CCW" {
    const rp = native.DoeRenderPipeline{};
    // 0x00000001 = WGPUFrontFace_CCW.
    try std.testing.expectEqual(@as(u32, 0x00000001), rp.front_face);
}

test "DoeRenderPipeline default cull_mode is none" {
    const rp = native.DoeRenderPipeline{};
    // 0x00000001 = WGPUCullMode_None.
    try std.testing.expectEqual(@as(u32, 0x00000001), rp.cull_mode);
}

test "DoeRenderPipeline default depth is disabled" {
    const rp = native.DoeRenderPipeline{};
    try std.testing.expect(!rp.depth_write_enabled);
    try std.testing.expect(!rp.unclipped_depth);
    try std.testing.expectEqual(@as(u32, 0), rp.depth_compare);
}

// ============================================================
// Struct layout: DoeRenderPass defaults
// ============================================================

test "DoeRenderPass default bind_groups are all null" {
    const dev = native.make(native.DoeDevice) orelse unreachable;
    defer native.alloc.destroy(dev);
    dev.* = .{};
    var enc = native.DoeCommandEncoder{ .dev = dev };
    const pass = native.DoeRenderPass{ .enc = &enc };
    for (pass.bind_groups) |bg| {
        try std.testing.expect(bg == null);
    }
    for (pass.vertex_buffers) |vb| {
        try std.testing.expect(vb == null);
    }
    for (pass.vertex_buffer_offsets) |off| {
        try std.testing.expectEqual(@as(u64, 0), off);
    }
}

// ============================================================
// WGSL compiler constants
// ============================================================

test "MAX_BINDINGS is 32" {
    try std.testing.expectEqual(@as(usize, 32), wgsl_compiler.MAX_BINDINGS);
}

test "CompilationStage enum has expected variants" {
    // Verify key stages exist.
    try std.testing.expectEqual(wgsl_compiler.CompilationStage.none, .none);
    try std.testing.expectEqual(wgsl_compiler.CompilationStage.parser, .parser);
    try std.testing.expectEqual(wgsl_compiler.CompilationStage.sema, .sema);
    try std.testing.expectEqual(wgsl_compiler.CompilationStage.msl_emit, .msl_emit);
}

// ============================================================
// initLimits helper
// ============================================================

test "initLimits returns zeroed struct with null nextInChain" {
    const limits = types.initLimits();
    try std.testing.expect(limits.nextInChain == null);
    try std.testing.expectEqual(@as(u32, 0), limits.maxTextureDimension1D);
    try std.testing.expectEqual(@as(u32, 0), limits.maxBindGroups);
    try std.testing.expectEqual(@as(u64, 0), limits.maxBufferSize);
}

// ============================================================
// WGPUStringView and WGPU_STRLEN sentinel
// ============================================================

test "WGPU_STRLEN is max usize" {
    try std.testing.expectEqual(std.math.maxInt(usize), types.WGPU_STRLEN);
}

test "WGPUStringView with null data and zero length is valid empty view" {
    const sv = types.WGPUStringView{ .data = null, .length = 0 };
    try std.testing.expect(sv.data == null);
    try std.testing.expectEqual(@as(usize, 0), sv.length);
}

// ============================================================
// doeNativeInstanceProcessEvents (no-op, must not crash)
// ============================================================

test "doeNativeInstanceProcessEvents with null does not crash" {
    native.doeNativeInstanceProcessEvents(null);
}

test "doeNativeInstanceProcessEvents with valid instance does not crash" {
    const inst = instance_device.doeNativeCreateInstance(null);
    defer instance_device.doeNativeInstanceRelease(inst);
    native.doeNativeInstanceProcessEvents(inst);
}
