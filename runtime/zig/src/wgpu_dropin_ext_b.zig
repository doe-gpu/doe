const std = @import("std");
const abi_core = @import("core/abi/wgpu_core_base_types.zig");
const abi_texture = @import("core/abi/wgpu_texture_base_types.zig");
const abi_copy = @import("core/abi/wgpu_copy_descriptor_types.zig");
const p1cap = @import("wgpu_p1_capability_procs.zig");
const p1res = @import("wgpu_p1_resource_table_procs.zig");
const p2life = @import("wgpu_p2_lifecycle_procs.zig");
const surface = @import("full/surface/wgpu_surface_procs.zig");
const texture = @import("wgpu_texture_procs.zig");
const render = @import("full/render/wgpu_render_api.zig");
const async_procs = @import("wgpu_async_procs.zig");
const async_pipeline = @import("wgpu_dropin_ext_a_pipeline.zig");
const native = @import("doe_wgpu_native.zig");

extern fn wgpuGetProcAddress(name: abi_core.WGPUStringView) callconv(.c) p1cap.WGPUProc;
extern fn doeWgpuDropinAbortMissingRequiredSymbol(name: abi_core.WGPUStringView) callconv(.c) noreturn;
const doeNativeRenderPassBeginOcclusionQuery = native.doeNativeRenderPassBeginOcclusionQuery;
const doeNativeRenderPassEndOcclusionQuery = native.doeNativeRenderPassEndOcclusionQuery;
const doeNativeRenderPassSetBlendConstant = native.doeNativeRenderPassSetBlendConstant;
const doeNativeRenderPassSetImmediates = native.doeNativeRenderPassSetImmediates;
const doeNativeRenderPassSetScissorRect = native.doeNativeRenderPassSetScissorRect;
const doeNativeRenderPassSetStencilReference = native.doeNativeRenderPassSetStencilReference;
const doeNativeRenderPassSetViewport = native.doeNativeRenderPassSetViewport;
const doeNativeRenderBundleEncoderSetImmediates = native.doeNativeRenderBundleEncoderSetImmediates;

fn symbolView(comptime name: []const u8) abi_core.WGPUStringView {
    return .{ .data = name.ptr, .length = name.len };
}

fn resolveRequiredProc(comptime FnType: type, comptime symbol_name: []const u8) FnType {
    const proc = wgpuGetProcAddress(symbolView(symbol_name)) orelse
        doeWgpuDropinAbortMissingRequiredSymbol(symbolView(symbol_name));
    return @as(FnType, @ptrCast(proc));
}

pub export fn wgpuRenderBundleEncoderSetImmediates(a0: p1res.WGPURenderBundleEncoder, a1: u32, a2: ?*const anyopaque, a3: usize) callconv(.c) void {
    doeNativeRenderBundleEncoderSetImmediates(a0, a1, if (a2) |ptr| @as([*]const u8, @ptrCast(ptr)) else null, a3);
}

pub export fn wgpuRenderBundleEncoderSetIndexBuffer(a0: render.RenderBundleEncoder, a1: abi_core.WGPUBuffer, a2: u32, a3: u64, a4: u64) callconv(.c) void {
    native.doeNativeRenderBundleEncoderSetIndexBuffer(a0, a1, a2, a3, a4);
}

pub export fn wgpuRenderBundleEncoderSetLabel(a0: render.RenderBundleEncoder, a1: abi_core.WGPUStringView) callconv(.c) void {
    native.doeNativeObjectSetLabel(a0, a1.data, a1.length);
}

pub export fn wgpuRenderBundleEncoderSetPipeline(a0: render.RenderBundleEncoder, a1: abi_core.WGPURenderPipeline) callconv(.c) void {
    native.doeNativeRenderBundleEncoderSetPipeline(a0, a1);
}

pub export fn wgpuRenderBundleEncoderSetResourceTable(a0: p1res.WGPURenderBundleEncoder, a1: p1res.WGPUResourceTable) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (p1res.WGPURenderBundleEncoder, p1res.WGPUResourceTable) callconv(.c) void, "wgpuRenderBundleEncoderSetResourceTable");
    proc(a0, a1);
}

pub export fn wgpuRenderBundleEncoderSetVertexBuffer(a0: render.RenderBundleEncoder, a1: u32, a2: abi_core.WGPUBuffer, a3: u64, a4: u64) callconv(.c) void {
    native.doeNativeRenderBundleEncoderSetVertexBuffer(a0, a1, a2, a3, a4);
}

pub export fn wgpuRenderBundleRelease(a0: render.RenderBundle) callconv(.c) void {
    native.doeNativeRenderBundleRelease(a0);
}

pub export fn wgpuRenderBundleSetLabel(a0: render.RenderBundle, a1: abi_core.WGPUStringView) callconv(.c) void {
    native.doeNativeObjectSetLabel(a0, a1.data, a1.length);
}

pub export fn wgpuRenderPassEncoderAddRef(a0: abi_core.WGPURenderPassEncoder) callconv(.c) void {
    native.object_add_ref(native.DoeRenderPass, a0);
}

pub export fn wgpuRenderPassEncoderBeginOcclusionQuery(a0: abi_core.WGPURenderPassEncoder, a1: u32) callconv(.c) void {
    doeNativeRenderPassBeginOcclusionQuery(a0, a1);
}

pub export fn wgpuRenderPassEncoderEndOcclusionQuery(a0: abi_core.WGPURenderPassEncoder) callconv(.c) void {
    doeNativeRenderPassEndOcclusionQuery(a0);
}

pub export fn wgpuRenderPassEncoderExecuteBundles(a0: abi_core.WGPURenderPassEncoder, a1: usize, a2: [*]const render.RenderBundle) callconv(.c) void {
    native.doeNativeRenderPassExecuteBundles(a0, a1, a2);
}

pub export fn wgpuRenderPassEncoderMultiDrawIndexedIndirect(a0: abi_core.WGPURenderPassEncoder, a1: abi_core.WGPUBuffer, a2: u64, a3: u32, a4: abi_core.WGPUBuffer, a5: u64) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (abi_core.WGPURenderPassEncoder, abi_core.WGPUBuffer, u64, u32, abi_core.WGPUBuffer, u64) callconv(.c) void, "wgpuRenderPassEncoderMultiDrawIndexedIndirect");
    proc(a0, a1, a2, a3, a4, a5);
}

pub export fn wgpuRenderPassEncoderMultiDrawIndirect(a0: abi_core.WGPURenderPassEncoder, a1: abi_core.WGPUBuffer, a2: u64, a3: u32, a4: abi_core.WGPUBuffer, a5: u64) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (abi_core.WGPURenderPassEncoder, abi_core.WGPUBuffer, u64, u32, abi_core.WGPUBuffer, u64) callconv(.c) void, "wgpuRenderPassEncoderMultiDrawIndirect");
    proc(a0, a1, a2, a3, a4, a5);
}

pub export fn wgpuRenderPassEncoderPixelLocalStorageBarrier(a0: abi_core.WGPURenderPassEncoder) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (abi_core.WGPURenderPassEncoder) callconv(.c) void, "wgpuRenderPassEncoderPixelLocalStorageBarrier");
    proc(a0);
}

pub export fn wgpuRenderPassEncoderSetBlendConstant(a0: abi_core.WGPURenderPassEncoder, a1: *const render.BlendColor) callconv(.c) void {
    doeNativeRenderPassSetBlendConstant(a0, a1.r, a1.g, a1.b, a1.a);
}

pub export fn wgpuRenderPassEncoderSetImmediates(a0: abi_core.WGPURenderPassEncoder, a1: u32, a2: ?*const anyopaque, a3: usize) callconv(.c) void {
    doeNativeRenderPassSetImmediates(a0, a1, if (a2) |ptr| @as([*]const u8, @ptrCast(ptr)) else null, a3);
}

pub export fn wgpuRenderPassEncoderSetResourceTable(a0: abi_core.WGPURenderPassEncoder, a1: p1res.WGPUResourceTable) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (abi_core.WGPURenderPassEncoder, p1res.WGPUResourceTable) callconv(.c) void, "wgpuRenderPassEncoderSetResourceTable");
    proc(a0, a1);
}

pub export fn wgpuRenderPassEncoderSetScissorRect(a0: abi_core.WGPURenderPassEncoder, a1: u32, a2: u32, a3: u32, a4: u32) callconv(.c) void {
    doeNativeRenderPassSetScissorRect(a0, a1, a2, a3, a4);
}

pub export fn wgpuRenderPassEncoderSetStencilReference(a0: abi_core.WGPURenderPassEncoder, a1: u32) callconv(.c) void {
    doeNativeRenderPassSetStencilReference(a0, a1);
}

pub export fn wgpuRenderPassEncoderSetViewport(a0: abi_core.WGPURenderPassEncoder, a1: f32, a2: f32, a3: f32, a4: f32, a5: f32, a6: f32) callconv(.c) void {
    doeNativeRenderPassSetViewport(a0, a1, a2, a3, a4, a5, a6);
}

pub export fn wgpuRenderPassEncoderWriteTimestamp(a0: abi_core.WGPURenderPassEncoder, a1: abi_core.WGPUQuerySet, a2: u32) callconv(.c) void {
    // Route through the command encoder timestamp path, extracting the
    // parent encoder from the render pass.
    const pass = native.cast(native.DoeRenderPass, a0) orelse return;
    const query_native = @import("doe_query_native.zig");
    query_native.doeNativeCommandEncoderWriteTimestamp(native.toOpaque(pass.enc), a1, a2);
}

pub export fn wgpuRenderPipelineAddRef(a0: abi_core.WGPURenderPipeline) callconv(.c) void {
    native.object_add_ref(native.DoeRenderPipeline, a0);
}

pub export fn wgpuRenderPipelineGetBindGroupLayout(a0: abi_core.WGPURenderPipeline, a1: u32) callconv(.c) abi_core.WGPUBindGroupLayout {
    return native.doeNativeRenderPipelineGetBindGroupLayout(a0, a1);
}

pub export fn wgpuResourceTableAddRef(a0: p1res.WGPUResourceTable) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (p1res.WGPUResourceTable) callconv(.c) void, "wgpuResourceTableAddRef");
    proc(a0);
}

pub export fn wgpuResourceTableDestroy(a0: p1res.WGPUResourceTable) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (p1res.WGPUResourceTable) callconv(.c) void, "wgpuResourceTableDestroy");
    proc(a0);
}

pub export fn wgpuResourceTableGetSize(a0: p1res.WGPUResourceTable) callconv(.c) u32 {
    const proc = resolveRequiredProc(*const fn (p1res.WGPUResourceTable) callconv(.c) u32, "wgpuResourceTableGetSize");
    return proc(a0);
}

pub export fn wgpuResourceTableInsertBinding(a0: p1res.WGPUResourceTable, a1: *const p1res.BindingResource) callconv(.c) u32 {
    const proc = resolveRequiredProc(*const fn (p1res.WGPUResourceTable, *const p1res.BindingResource) callconv(.c) u32, "wgpuResourceTableInsertBinding");
    return proc(a0, a1);
}

pub export fn wgpuResourceTableRelease(a0: p1res.WGPUResourceTable) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (p1res.WGPUResourceTable) callconv(.c) void, "wgpuResourceTableRelease");
    proc(a0);
}

pub export fn wgpuResourceTableRemoveBinding(a0: p1res.WGPUResourceTable, a1: u32) callconv(.c) abi_core.WGPUStatus {
    const proc = resolveRequiredProc(*const fn (p1res.WGPUResourceTable, u32) callconv(.c) abi_core.WGPUStatus, "wgpuResourceTableRemoveBinding");
    return proc(a0, a1);
}

pub export fn wgpuResourceTableUpdate(a0: p1res.WGPUResourceTable, a1: u32, a2: *const p1res.BindingResource) callconv(.c) abi_core.WGPUStatus {
    const proc = resolveRequiredProc(*const fn (p1res.WGPUResourceTable, u32, *const p1res.BindingResource) callconv(.c) abi_core.WGPUStatus, "wgpuResourceTableUpdate");
    return proc(a0, a1, a2);
}

pub export fn wgpuSamplerAddRef(a0: abi_core.WGPUSampler) callconv(.c) void {
    native.object_add_ref(native.DoeSampler, a0);
}

pub export fn wgpuShaderModuleAddRef(a0: abi_core.WGPUShaderModule) callconv(.c) void {
    native.object_add_ref(native.DoeShaderModule, a0);
}

pub export fn wgpuShaderModuleGetCompilationInfo(a0: abi_core.WGPUShaderModule, a1: async_procs.CompilationInfoCallbackInfo) callconv(.c) abi_core.WGPUFuture {
    const future = abi_core.WGPUFuture{ .id = async_pipeline.next_async_future_id() };
    if (a1.callback) |cb| {
        const module = native.cast(native.DoeShaderModule, a0) orelse {
            cb(
                async_procs.COMPILATION_INFO_STATUS_CALLBACK_CANCELLED,
                null,
                a1.userdata1,
                a1.userdata2,
            );
            return future;
        };
        var message_storage: async_procs.CompilationMessageABI = undefined;
        var info = async_procs.CompilationInfoABI{
            .nextInChain = null,
            .messageCount = 0,
            .messages = null,
        };
        if (module.compilation_message) |message| {
            const message_type: u32 = switch (module.compilation_message_kind) {
                .@"error" => async_procs.COMPILATION_MESSAGE_TYPE_ERROR,
                .warning => async_procs.COMPILATION_MESSAGE_TYPE_WARNING,
                .info => async_procs.COMPILATION_MESSAGE_TYPE_INFO,
                .none => 0,
            };
            if (message_type != 0) {
                message_storage = .{
                    .nextInChain = null,
                    .message = .{ .data = message.ptr, .length = message.len },
                    .message_type = message_type,
                    .lineNum = module.compilation_message_line,
                    .linePos = module.compilation_message_column,
                    .offset = 0,
                    .length = 0,
                };
                info.messageCount = 1;
                info.messages = &message_storage;
            }
        }
        cb(
            async_procs.COMPILATION_INFO_STATUS_SUCCESS,
            &info,
            a1.userdata1,
            a1.userdata2,
        );
    }
    return future;
}

const CompilationInfoCapture = struct {
    called: bool = false,
    status: u32 = 0,
    message_count: usize = 0,
    message_type: u32 = 0,
    line: u64 = 0,
    column: u64 = 0,
    message_len: usize = 0,
    message: [128]u8 = [_]u8{0} ** 128,
};

fn captureCompilationInfo(
    status: u32,
    info: ?*const async_procs.CompilationInfoABI,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = userdata2;
    const capture: *CompilationInfoCapture = @ptrCast(@alignCast(userdata1 orelse return));
    capture.called = true;
    capture.status = status;
    const compilation_info = info orelse return;
    capture.message_count = compilation_info.messageCount;
    const message = compilation_info.messages orelse return;
    capture.message_type = message.message_type;
    capture.line = message.lineNum;
    capture.column = message.linePos;
    const source = message.message.data orelse return;
    capture.message_len = @min(message.message.length, capture.message.len);
    @memcpy(capture.message[0..capture.message_len], source[0..capture.message_len]);
}

test "shader compilation info surfaces Doe module diagnostics" {
    const diagnostic = "unknown type missing_type";
    var module = native.DoeShaderModule{
        .compilation_message_kind = .@"error",
        .compilation_message = diagnostic,
        .compilation_message_line = 4,
        .compilation_message_column = 7,
    };
    var capture = CompilationInfoCapture{};
    const future = wgpuShaderModuleGetCompilationInfo(native.toOpaque(&module), .{
        .nextInChain = null,
        .mode = 3,
        .callback = captureCompilationInfo,
        .userdata1 = &capture,
        .userdata2 = null,
    });

    try std.testing.expect(future.id != 0);
    try std.testing.expect(capture.called);
    try std.testing.expectEqual(async_procs.COMPILATION_INFO_STATUS_SUCCESS, capture.status);
    try std.testing.expectEqual(@as(usize, 1), capture.message_count);
    try std.testing.expectEqual(async_procs.COMPILATION_MESSAGE_TYPE_ERROR, capture.message_type);
    try std.testing.expectEqual(@as(u64, 4), capture.line);
    try std.testing.expectEqual(@as(u64, 7), capture.column);
    try std.testing.expectEqualStrings(diagnostic, capture.message[0..capture.message_len]);
}

pub export fn wgpuSharedBufferMemoryAddRef(a0: p2life.WGPUSharedBufferMemory) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (p2life.WGPUSharedBufferMemory) callconv(.c) void, "wgpuSharedBufferMemoryAddRef");
    proc(a0);
}

pub export fn wgpuSharedFenceAddRef(a0: p2life.WGPUSharedFence) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (p2life.WGPUSharedFence) callconv(.c) void, "wgpuSharedFenceAddRef");
    proc(a0);
}

pub export fn wgpuSharedTextureMemoryAddRef(a0: p2life.WGPUSharedTextureMemory) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (p2life.WGPUSharedTextureMemory) callconv(.c) void, "wgpuSharedTextureMemoryAddRef");
    proc(a0);
}

pub export fn wgpuSupportedFeaturesFreeMembers(a0: p1cap.SupportedFeatures) callconv(.c) void {
    const features = a0.features orelse return;
    std.heap.c_allocator.free(features[0..a0.featureCount]);
}

pub export fn wgpuSupportedInstanceFeaturesFreeMembers(a0: p1cap.SupportedInstanceFeatures) callconv(.c) void {
    _ = a0;
}

pub export fn wgpuSupportedWGSLLanguageFeaturesFreeMembers(a0: p1cap.SupportedWGSLLanguageFeatures) callconv(.c) void {
    _ = a0;
}

pub export fn wgpuSurfaceAddRef(a0: p2life.WGPUSurface) callconv(.c) void {
    native.object_add_ref(native.DoeSurface, a0);
}

pub export fn wgpuSurfaceCapabilitiesFreeMembers(a0: surface.SurfaceCapabilities) callconv(.c) void {
    // Doe surfaces use static arrays; FreeMembers is a no-op for them.
    // We cannot distinguish ownership here, so always call native (safe for static data)
    // then fall through to Dawn if needed.
    native.doeNativeSurfaceCapabilitiesFreeMembers(a0);
}

pub export fn wgpuSurfaceConfigure(a0: surface.Surface, a1: *const surface.SurfaceConfiguration) callconv(.c) void {
    if (native.cast(native.DoeSurface, a0) != null) {
        native.doeAbiBridgeSurfaceConfigure(a0, a1);
        return;
    }
    const proc = resolveRequiredProc(*const fn (surface.Surface, *const surface.SurfaceConfiguration) callconv(.c) void, "wgpuSurfaceConfigure");
    proc(a0, a1);
}

pub export fn wgpuSurfaceGetCapabilities(a0: surface.Surface, a1: abi_core.WGPUAdapter, a2: *surface.SurfaceCapabilities) callconv(.c) u32 {
    if (native.cast(native.DoeSurface, a0) != null) return native.doeNativeSurfaceGetCapabilities(a0, a1, a2);
    const proc = resolveRequiredProc(*const fn (surface.Surface, abi_core.WGPUAdapter, *surface.SurfaceCapabilities) callconv(.c) u32, "wgpuSurfaceGetCapabilities");
    return proc(a0, a1, a2);
}

pub export fn wgpuSurfaceGetCurrentTexture(a0: surface.Surface, a1: *surface.SurfaceTexture) callconv(.c) void {
    if (native.cast(native.DoeSurface, a0) != null) {
        native.doeAbiBridgeSurfaceGetCurrentTexture(a0, a1);
        return;
    }
    const proc = resolveRequiredProc(*const fn (surface.Surface, *surface.SurfaceTexture) callconv(.c) void, "wgpuSurfaceGetCurrentTexture");
    proc(a0, a1);
}

pub export fn wgpuSurfacePresent(a0: surface.Surface) callconv(.c) u32 {
    if (native.cast(native.DoeSurface, a0) != null) return native.doeAbiBridgeSurfacePresent(a0);
    const proc = resolveRequiredProc(*const fn (surface.Surface) callconv(.c) u32, "wgpuSurfacePresent");
    return proc(a0);
}

pub export fn wgpuSurfaceRelease(a0: surface.Surface) callconv(.c) void {
    if (native.cast(native.DoeSurface, a0) != null) {
        native.doeNativeSurfaceRelease(a0);
        return;
    }
    const proc = resolveRequiredProc(*const fn (surface.Surface) callconv(.c) void, "wgpuSurfaceRelease");
    proc(a0);
}

pub export fn wgpuSurfaceUnconfigure(a0: surface.Surface) callconv(.c) void {
    if (native.cast(native.DoeSurface, a0) != null) {
        native.doeNativeSurfaceUnconfigure(a0);
        return;
    }
    const proc = resolveRequiredProc(*const fn (surface.Surface) callconv(.c) void, "wgpuSurfaceUnconfigure");
    proc(a0);
}

pub export fn wgpuTexelBufferViewAddRef(a0: p2life.WGPUTexelBufferView) callconv(.c) void {
    const proc = resolveRequiredProc(*const fn (p2life.WGPUTexelBufferView) callconv(.c) void, "wgpuTexelBufferViewAddRef");
    proc(a0);
}

pub export fn wgpuTextureAddRef(a0: abi_core.WGPUTexture) callconv(.c) void {
    native.object_add_ref(native.DoeTexture, a0);
}

pub export fn wgpuTextureDestroy(a0: abi_core.WGPUTexture) callconv(.c) void {
    native.doeNativeTextureDestroy(a0);
}

// ABI bridges for texture copy commands: the Doe native implementations use
// flattened individual parameters while the WebGPU C ABI passes struct pointers.

pub fn doeAbiBridgeCopyTextureToBuffer(
    encoder: abi_core.WGPUCommandEncoder,
    source: *const abi_copy.WGPUTexelCopyTextureInfo,
    destination: *const abi_copy.WGPUTexelCopyBufferInfo,
    copy_size: *const abi_copy.WGPUExtent3D,
) callconv(.c) void {
    const encoder_native = @import("doe_encoder_native.zig");
    encoder_native.doeNativeCommandEncoderCopyTextureToBuffer(
        encoder,
        source.texture,
        source.mipLevel,
        destination.buffer,
        destination.layout.offset,
        destination.layout.bytesPerRow,
        destination.layout.rowsPerImage,
        copy_size.width,
        copy_size.height,
        copy_size.depthOrArrayLayers,
    );
}

pub fn doeAbiBridgeCopyBufferToTexture(
    encoder: abi_core.WGPUCommandEncoder,
    source: *const abi_copy.WGPUTexelCopyBufferInfo,
    destination: *const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size: *const abi_copy.WGPUExtent3D,
) callconv(.c) void {
    const encoder_native = @import("doe_encoder_native.zig");
    encoder_native.doeNativeCommandEncoderCopyBufferToTexture(
        encoder,
        source.buffer,
        source.layout.offset,
        source.layout.bytesPerRow,
        source.layout.rowsPerImage,
        destination.texture,
        destination.mipLevel,
        copy_size.width,
        copy_size.height,
        copy_size.depthOrArrayLayers,
    );
}

pub fn doeAbiBridgeCopyTextureToTexture(
    encoder: abi_core.WGPUCommandEncoder,
    source: *const abi_copy.WGPUTexelCopyTextureInfo,
    destination: *const abi_copy.WGPUTexelCopyTextureInfo,
    copy_size: *const abi_copy.WGPUExtent3D,
) callconv(.c) void {
    const cmd_texture = @import("doe_command_texture_native.zig");
    cmd_texture.doeNativeCommandEncoderCopyTextureToTexture(
        encoder,
        source.texture,
        source.mipLevel,
        0,
        source.origin.x,
        source.origin.y,
        source.origin.z,
        destination.texture,
        destination.mipLevel,
        0,
        destination.origin.x,
        destination.origin.y,
        destination.origin.z,
        copy_size.width,
        copy_size.height,
        copy_size.depthOrArrayLayers,
    );
}

pub export fn wgpuTextureGetDepthOrArrayLayers(a0: abi_core.WGPUTexture) callconv(.c) u32 {
    if (native.cast(native.DoeTexture, a0)) |tex| return tex.depth_or_array_layers;
    return 0;
}

pub export fn wgpuTextureGetDimension(a0: abi_core.WGPUTexture) callconv(.c) abi_texture.WGPUTextureDimension {
    if (native.cast(native.DoeTexture, a0)) |tex| return tex.dimension;
    return 0;
}

pub export fn wgpuTextureGetFormat(a0: abi_core.WGPUTexture) callconv(.c) abi_texture.WGPUTextureFormat {
    if (native.cast(native.DoeTexture, a0)) |tex| return tex.format;
    return 0;
}

pub export fn wgpuTextureGetHeight(a0: abi_core.WGPUTexture) callconv(.c) u32 {
    if (native.cast(native.DoeTexture, a0)) |tex| return tex.height;
    return 0;
}

pub export fn wgpuTextureGetMipLevelCount(a0: abi_core.WGPUTexture) callconv(.c) u32 {
    if (native.cast(native.DoeTexture, a0)) |tex| return tex.mip_level_count;
    return 0;
}

pub export fn wgpuTextureGetSampleCount(a0: abi_core.WGPUTexture) callconv(.c) u32 {
    if (native.cast(native.DoeTexture, a0)) |tex| return tex.sample_count;
    return 0;
}

pub export fn wgpuTextureGetTextureBindingViewDimension(a0: abi_core.WGPUTexture) callconv(.c) abi_texture.WGPUTextureViewDimension {
    if (native.cast(native.DoeTexture, a0)) |tex| return tex.texture_binding_view_dimension;
    return 0;
}

pub export fn wgpuTextureGetUsage(a0: abi_core.WGPUTexture) callconv(.c) abi_texture.WGPUTextureUsage {
    if (native.cast(native.DoeTexture, a0)) |tex| return tex.usage;
    return 0;
}

pub export fn wgpuTextureGetWidth(a0: abi_core.WGPUTexture) callconv(.c) u32 {
    if (native.cast(native.DoeTexture, a0)) |tex| return tex.width;
    return 0;
}

pub export fn wgpuTextureViewAddRef(a0: abi_core.WGPUTextureView) callconv(.c) void {
    native.object_add_ref(native.DoeTextureView, a0);
}
