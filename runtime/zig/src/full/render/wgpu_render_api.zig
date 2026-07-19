const std = @import("std");
const abi_base = @import("../../core/abi/wgpu_handle_types.zig");
const abi_proc_aliases = @import("../../core/abi/wgpu_type_proc_aliases.zig");
const p0_procs_mod = @import("../../core/abi/procs/wgpu_p0_procs.zig");
const render_types_mod = @import("wgpu_render_types.zig");

pub const RenderBundle = ?*anyopaque;
pub const RenderBundleEncoder = ?*anyopaque;

pub const BlendColor = render_types_mod.RenderColor;

const FnRenderPassEncoderSetViewport = *const fn (abi_base.WGPURenderPassEncoder, f32, f32, f32, f32, f32, f32) callconv(.c) void;
const FnRenderPassEncoderSetScissorRect = *const fn (abi_base.WGPURenderPassEncoder, u32, u32, u32, u32) callconv(.c) void;
const FnRenderPassEncoderSetBlendConstant = *const fn (abi_base.WGPURenderPassEncoder, *const BlendColor) callconv(.c) void;
const FnRenderPassEncoderSetStencilReference = *const fn (abi_base.WGPURenderPassEncoder, u32) callconv(.c) void;
const FnRenderPipelineGetBindGroupLayout = *const fn (abi_base.WGPURenderPipeline, u32) callconv(.c) abi_base.WGPUBindGroupLayout;

const FnDeviceCreateRenderBundleEncoder = *const fn (abi_base.WGPUDevice, *const anyopaque) callconv(.c) RenderBundleEncoder;
const FnRenderBundleEncoderDraw = *const fn (RenderBundleEncoder, u32, u32, u32, u32) callconv(.c) void;
const FnRenderBundleEncoderDrawIndexed = *const fn (RenderBundleEncoder, u32, u32, u32, i32, u32) callconv(.c) void;
const FnRenderBundleEncoderDrawIndirect = *const fn (RenderBundleEncoder, abi_base.WGPUBuffer, u64) callconv(.c) void;
const FnRenderBundleEncoderDrawIndexedIndirect = *const fn (RenderBundleEncoder, abi_base.WGPUBuffer, u64) callconv(.c) void;
const FnRenderBundleEncoderFinish = *const fn (RenderBundleEncoder, ?*const anyopaque) callconv(.c) RenderBundle;
const FnRenderBundleEncoderInsertDebugMarker = *const fn (RenderBundleEncoder, abi_base.WGPUStringView) callconv(.c) void;
const FnRenderBundleEncoderPopDebugGroup = *const fn (RenderBundleEncoder) callconv(.c) void;
const FnRenderBundleEncoderPushDebugGroup = *const fn (RenderBundleEncoder, abi_base.WGPUStringView) callconv(.c) void;
const FnRenderBundleEncoderSetBindGroup = *const fn (RenderBundleEncoder, u32, abi_base.WGPUBindGroup, usize, ?[*]const u32) callconv(.c) void;
const FnRenderBundleEncoderSetIndexBuffer = *const fn (RenderBundleEncoder, abi_base.WGPUBuffer, u32, u64, u64) callconv(.c) void;
const FnRenderBundleEncoderSetLabel = *const fn (RenderBundleEncoder, abi_base.WGPUStringView) callconv(.c) void;
const FnRenderBundleEncoderSetPipeline = *const fn (RenderBundleEncoder, abi_base.WGPURenderPipeline) callconv(.c) void;
const FnRenderBundleEncoderSetVertexBuffer = *const fn (RenderBundleEncoder, u32, abi_base.WGPUBuffer, u64, u64) callconv(.c) void;
const FnRenderBundleEncoderAddRef = *const fn (RenderBundleEncoder) callconv(.c) void;
const FnRenderBundleEncoderRelease = *const fn (RenderBundleEncoder) callconv(.c) void;
const FnRenderPassEncoderExecuteBundles = *const fn (abi_base.WGPURenderPassEncoder, usize, [*]const RenderBundle) callconv(.c) void;
const FnRenderBundleSetLabel = *const fn (RenderBundle, abi_base.WGPUStringView) callconv(.c) void;
const FnRenderBundleAddRef = *const fn (RenderBundle) callconv(.c) void;
const FnRenderBundleRelease = *const fn (RenderBundle) callconv(.c) void;

pub const RenderApi = struct {
    device_create_render_pipeline: abi_proc_aliases.FnWgpuDeviceCreateRenderPipeline,
    command_encoder_begin_render_pass: abi_proc_aliases.FnWgpuCommandEncoderBeginRenderPass,
    render_pass_encoder_set_pipeline: abi_proc_aliases.FnWgpuRenderPassEncoderSetPipeline,
    render_pass_encoder_set_vertex_buffer: abi_proc_aliases.FnWgpuRenderPassEncoderSetVertexBuffer,
    render_pass_encoder_set_index_buffer: abi_proc_aliases.FnWgpuRenderPassEncoderSetIndexBuffer,
    render_pass_encoder_set_bind_group: abi_proc_aliases.FnWgpuRenderPassEncoderSetBindGroup,
    render_pass_encoder_draw: abi_proc_aliases.FnWgpuRenderPassEncoderDraw,
    render_pass_encoder_draw_indexed: abi_proc_aliases.FnWgpuRenderPassEncoderDrawIndexed,
    render_pass_encoder_draw_indirect: abi_proc_aliases.FnWgpuRenderPassEncoderDrawIndirect,
    render_pass_encoder_draw_indexed_indirect: abi_proc_aliases.FnWgpuRenderPassEncoderDrawIndexedIndirect,
    render_pass_encoder_end: abi_proc_aliases.FnWgpuRenderPassEncoderEnd,
    render_pass_encoder_release: abi_proc_aliases.FnWgpuRenderPassEncoderRelease,
    render_pipeline_release: abi_proc_aliases.FnWgpuRenderPipelineRelease,
    render_pass_encoder_set_viewport: FnRenderPassEncoderSetViewport,
    render_pass_encoder_set_scissor_rect: FnRenderPassEncoderSetScissorRect,
    render_pass_encoder_set_blend_constant: FnRenderPassEncoderSetBlendConstant,
    render_pass_encoder_set_stencil_reference: FnRenderPassEncoderSetStencilReference,
    render_pipeline_get_bind_group_layout: FnRenderPipelineGetBindGroupLayout,
    device_create_render_bundle_encoder: FnDeviceCreateRenderBundleEncoder,
    render_bundle_encoder_draw: FnRenderBundleEncoderDraw,
    render_bundle_encoder_draw_indexed: FnRenderBundleEncoderDrawIndexed,
    render_bundle_encoder_draw_indirect: FnRenderBundleEncoderDrawIndirect,
    render_bundle_encoder_draw_indexed_indirect: FnRenderBundleEncoderDrawIndexedIndirect,
    render_bundle_encoder_finish: FnRenderBundleEncoderFinish,
    render_bundle_encoder_insert_debug_marker: FnRenderBundleEncoderInsertDebugMarker,
    render_bundle_encoder_pop_debug_group: FnRenderBundleEncoderPopDebugGroup,
    render_bundle_encoder_push_debug_group: FnRenderBundleEncoderPushDebugGroup,
    render_bundle_encoder_set_bind_group: FnRenderBundleEncoderSetBindGroup,
    render_bundle_encoder_set_index_buffer: FnRenderBundleEncoderSetIndexBuffer,
    render_bundle_encoder_set_label: FnRenderBundleEncoderSetLabel,
    render_bundle_encoder_set_pipeline: FnRenderBundleEncoderSetPipeline,
    render_bundle_encoder_set_vertex_buffer: FnRenderBundleEncoderSetVertexBuffer,
    render_bundle_encoder_add_ref: FnRenderBundleEncoderAddRef,
    render_bundle_encoder_release: FnRenderBundleEncoderRelease,
    render_pass_encoder_execute_bundles: FnRenderPassEncoderExecuteBundles,
    render_bundle_set_label: FnRenderBundleSetLabel,
    render_bundle_add_ref: FnRenderBundleAddRef,
    render_bundle_release: FnRenderBundleRelease,
    render_pass_encoder_begin_occlusion_query: ?p0_procs_mod.FnRenderPassEncoderBeginOcclusionQuery,
    render_pass_encoder_end_occlusion_query: ?p0_procs_mod.FnRenderPassEncoderEndOcclusionQuery,
    render_pass_encoder_multi_draw_indexed_indirect: ?p0_procs_mod.FnRenderPassEncoderMultiDrawIndexedIndirect,
    render_pass_encoder_multi_draw_indirect: ?p0_procs_mod.FnRenderPassEncoderMultiDrawIndirect,
    render_pass_encoder_pixel_local_storage_barrier: ?p0_procs_mod.FnRenderPassEncoderPixelLocalStorageBarrier,
    render_pass_encoder_write_timestamp: ?p0_procs_mod.FnRenderPassEncoderWriteTimestamp,
};

const LoadState = enum {
    uninitialized,
    unavailable,
    ready,
};

var load_state: LoadState = .uninitialized;
var cached_render_api: RenderApi = undefined;

fn loadProc(comptime T: type, lib: std.DynLib, comptime name: [:0]const u8) ?T {
    var mutable = lib;
    return mutable.lookup(T, name);
}

pub fn loadRenderApi(procs: abi_proc_aliases.Procs, dyn_lib: ?std.DynLib) ?RenderApi {
    switch (load_state) {
        .ready => return cached_render_api,
        .unavailable => return null,
        .uninitialized => {},
    }
    const lib = dyn_lib orelse return null;
    const p0_procs = p0_procs_mod.loadP0Procs(dyn_lib);
    const loaded = RenderApi{
        .device_create_render_pipeline = procs.wgpuDeviceCreateRenderPipeline orelse return null,
        .command_encoder_begin_render_pass = procs.wgpuCommandEncoderBeginRenderPass orelse return null,
        .render_pass_encoder_set_pipeline = procs.wgpuRenderPassEncoderSetPipeline orelse return null,
        .render_pass_encoder_set_vertex_buffer = procs.wgpuRenderPassEncoderSetVertexBuffer orelse return null,
        .render_pass_encoder_set_index_buffer = procs.wgpuRenderPassEncoderSetIndexBuffer orelse return null,
        .render_pass_encoder_set_bind_group = procs.wgpuRenderPassEncoderSetBindGroup orelse return null,
        .render_pass_encoder_draw = procs.wgpuRenderPassEncoderDraw orelse return null,
        .render_pass_encoder_draw_indexed = procs.wgpuRenderPassEncoderDrawIndexed orelse return null,
        .render_pass_encoder_draw_indirect = procs.wgpuRenderPassEncoderDrawIndirect orelse return null,
        .render_pass_encoder_draw_indexed_indirect = procs.wgpuRenderPassEncoderDrawIndexedIndirect orelse return null,
        .render_pass_encoder_end = procs.wgpuRenderPassEncoderEnd orelse return null,
        .render_pass_encoder_release = procs.wgpuRenderPassEncoderRelease orelse return null,
        .render_pipeline_release = procs.wgpuRenderPipelineRelease orelse return null,
        .render_pass_encoder_set_viewport = loadProc(FnRenderPassEncoderSetViewport, lib, "wgpuRenderPassEncoderSetViewport") orelse return null,
        .render_pass_encoder_set_scissor_rect = loadProc(FnRenderPassEncoderSetScissorRect, lib, "wgpuRenderPassEncoderSetScissorRect") orelse return null,
        .render_pass_encoder_set_blend_constant = loadProc(FnRenderPassEncoderSetBlendConstant, lib, "wgpuRenderPassEncoderSetBlendConstant") orelse return null,
        .render_pass_encoder_set_stencil_reference = loadProc(FnRenderPassEncoderSetStencilReference, lib, "wgpuRenderPassEncoderSetStencilReference") orelse return null,
        .render_pipeline_get_bind_group_layout = loadProc(FnRenderPipelineGetBindGroupLayout, lib, "wgpuRenderPipelineGetBindGroupLayout") orelse return null,
        .device_create_render_bundle_encoder = loadProc(FnDeviceCreateRenderBundleEncoder, lib, "wgpuDeviceCreateRenderBundleEncoder") orelse return null,
        .render_bundle_encoder_draw = loadProc(FnRenderBundleEncoderDraw, lib, "wgpuRenderBundleEncoderDraw") orelse return null,
        .render_bundle_encoder_draw_indexed = loadProc(FnRenderBundleEncoderDrawIndexed, lib, "wgpuRenderBundleEncoderDrawIndexed") orelse return null,
        .render_bundle_encoder_draw_indirect = loadProc(FnRenderBundleEncoderDrawIndirect, lib, "wgpuRenderBundleEncoderDrawIndirect") orelse return null,
        .render_bundle_encoder_draw_indexed_indirect = loadProc(FnRenderBundleEncoderDrawIndexedIndirect, lib, "wgpuRenderBundleEncoderDrawIndexedIndirect") orelse return null,
        .render_bundle_encoder_finish = loadProc(FnRenderBundleEncoderFinish, lib, "wgpuRenderBundleEncoderFinish") orelse return null,
        .render_bundle_encoder_insert_debug_marker = loadProc(FnRenderBundleEncoderInsertDebugMarker, lib, "wgpuRenderBundleEncoderInsertDebugMarker") orelse return null,
        .render_bundle_encoder_pop_debug_group = loadProc(FnRenderBundleEncoderPopDebugGroup, lib, "wgpuRenderBundleEncoderPopDebugGroup") orelse return null,
        .render_bundle_encoder_push_debug_group = loadProc(FnRenderBundleEncoderPushDebugGroup, lib, "wgpuRenderBundleEncoderPushDebugGroup") orelse return null,
        .render_bundle_encoder_set_bind_group = loadProc(FnRenderBundleEncoderSetBindGroup, lib, "wgpuRenderBundleEncoderSetBindGroup") orelse return null,
        .render_bundle_encoder_set_index_buffer = loadProc(FnRenderBundleEncoderSetIndexBuffer, lib, "wgpuRenderBundleEncoderSetIndexBuffer") orelse return null,
        .render_bundle_encoder_set_label = loadProc(FnRenderBundleEncoderSetLabel, lib, "wgpuRenderBundleEncoderSetLabel") orelse return null,
        .render_bundle_encoder_set_pipeline = loadProc(FnRenderBundleEncoderSetPipeline, lib, "wgpuRenderBundleEncoderSetPipeline") orelse return null,
        .render_bundle_encoder_set_vertex_buffer = loadProc(FnRenderBundleEncoderSetVertexBuffer, lib, "wgpuRenderBundleEncoderSetVertexBuffer") orelse return null,
        .render_bundle_encoder_add_ref = loadProc(FnRenderBundleEncoderAddRef, lib, "wgpuRenderBundleEncoderAddRef") orelse return null,
        .render_bundle_encoder_release = loadProc(FnRenderBundleEncoderRelease, lib, "wgpuRenderBundleEncoderRelease") orelse return null,
        .render_pass_encoder_execute_bundles = loadProc(FnRenderPassEncoderExecuteBundles, lib, "wgpuRenderPassEncoderExecuteBundles") orelse return null,
        .render_bundle_set_label = loadProc(FnRenderBundleSetLabel, lib, "wgpuRenderBundleSetLabel") orelse return null,
        .render_bundle_add_ref = loadProc(FnRenderBundleAddRef, lib, "wgpuRenderBundleAddRef") orelse return null,
        .render_bundle_release = loadProc(FnRenderBundleRelease, lib, "wgpuRenderBundleRelease") orelse return null,
        .render_pass_encoder_begin_occlusion_query = if (p0_procs) |loaded| loaded.render_pass_encoder_begin_occlusion_query else null,
        .render_pass_encoder_end_occlusion_query = if (p0_procs) |loaded| loaded.render_pass_encoder_end_occlusion_query else null,
        .render_pass_encoder_multi_draw_indexed_indirect = if (p0_procs) |loaded| loaded.render_pass_encoder_multi_draw_indexed_indirect else null,
        .render_pass_encoder_multi_draw_indirect = if (p0_procs) |loaded| loaded.render_pass_encoder_multi_draw_indirect else null,
        .render_pass_encoder_pixel_local_storage_barrier = if (p0_procs) |loaded| loaded.render_pass_encoder_pixel_local_storage_barrier else null,
        .render_pass_encoder_write_timestamp = if (p0_procs) |loaded| loaded.render_pass_encoder_write_timestamp else null,
    };
    cached_render_api = loaded;
    load_state = .ready;
    return loaded;
}
