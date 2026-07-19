const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const proc_types = @import("../../core/abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const loader = @import("../../core/abi/wgpu_loader.zig");
const resources = @import("../../core/resource/wgpu_resources.zig");
const render_resource_mod = @import("wgpu_render_resources.zig");
const rc = @import("wgpu_render_constants.zig");

pub const TempRenderTextureResult = struct {
    view: ?abi_base.WGPUTextureView,
    needs_copy_back: bool,
};

/// Determines whether a temp render texture is needed for the given render
/// command and, if so, creates the temp texture and view. Formats affected
/// by the mip-level workaround are redirected through a scratch texture at
/// mip 0 so the render attachment requirement is satisfied.
pub fn setupTempRenderTexture(
    self: anytype,
    render: model_render_types.RenderDrawCommand,
    target_format: abi_base.WGPUTextureFormat,
    target_resource: model_resource_types.CopyTextureResource,
) !TempRenderTextureResult {
    const needs_temp = render.uses_temporary_render_texture and
        rc.is_affected_render_format(target_format) and
        target_resource.mip_level >= render.temporary_render_texture_min_mip_level;

    if (!needs_temp) {
        return .{ .view = null, .needs_copy_back = false };
    }

    const temp_handle = render.target_handle +% rc.TEMP_RENDER_TEXTURE_OFFSET;
    const temp_resource = model_resource_types.CopyTextureResource{
        .handle = temp_handle,
        .kind = .texture,
        .width = render.target_width,
        .height = render.target_height,
        .depth_or_array_layers = 1,
        .format = render.target_format,
        .usage = abi_base.WGPUTextureUsage_RenderAttachment | abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_CopyDst,
        .dimension = model_gpu_types.WGPUTextureDimension_2D,
        .view_dimension = model_gpu_types.WGPUTextureViewDimension_2D,
        .mip_level = 0,
        .sample_count = 1,
        .aspect = model_gpu_types.WGPUTextureAspect_All,
        .bytes_per_row = 0,
        .rows_per_image = 0,
        .offset = 0,
    };
    const temp_texture = try resources.getOrCreateTexture(
        self,
        temp_resource,
        abi_base.WGPUTextureUsage_RenderAttachment | abi_base.WGPUTextureUsage_CopySrc | abi_base.WGPUTextureUsage_CopyDst,
    );
    const temp_view = render_resource_mod.getOrCreateCachedRenderTextureView(
        self,
        &self.full.render_target_view_cache,
        temp_handle,
        temp_texture,
        render.target_width,
        render.target_height,
        target_format,
        abi_base.WGPUTextureUsage_RenderAttachment,
    ) catch {
        return error.TempRenderTextureViewFailed;
    };
    return .{ .view = temp_view, .needs_copy_back = true };
}

/// Copies the temp render texture back to the original target texture after
/// the render pass. The copy goes from mip 0 of the temp texture to the
/// original mip level of the target.
pub fn copyBackTempRenderTexture(
    self: anytype,
    procs: anytype,
    encoder: anytype,
    render: model_render_types.RenderDrawCommand,
    target_texture: abi_base.WGPUTexture,
    target_resource: model_resource_types.CopyTextureResource,
) !void {
    const temp_handle = render.target_handle +% rc.TEMP_RENDER_TEXTURE_OFFSET;
    const temp_resource_src = model_resource_types.CopyTextureResource{
        .handle = temp_handle,
        .kind = .texture,
        .width = render.target_width,
        .height = render.target_height,
        .depth_or_array_layers = 1,
        .format = render.target_format,
        .usage = abi_base.WGPUTextureUsage_CopySrc,
        .dimension = model_gpu_types.WGPUTextureDimension_2D,
        .view_dimension = model_gpu_types.WGPUTextureViewDimension_2D,
        .mip_level = 0,
        .sample_count = 1,
        .aspect = model_gpu_types.WGPUTextureAspect_All,
        .bytes_per_row = 0,
        .rows_per_image = 0,
        .offset = 0,
    };
    const temp_src = try resources.getOrCreateTexture(self, temp_resource_src, abi_base.WGPUTextureUsage_CopySrc);
    const copy_extent = abi_descriptor.WGPUExtent3D{
        .width = render.target_width,
        .height = render.target_height,
        .depthOrArrayLayers = 1,
    };
    procs.wgpuCommandEncoderCopyTextureToTexture(
        encoder,
        &abi_descriptor.WGPUTexelCopyTextureInfo{
            .texture = temp_src,
            .mipLevel = 0,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = loader.normalizeTextureAspect(model_gpu_types.WGPUTextureAspect_All),
        },
        &abi_descriptor.WGPUTexelCopyTextureInfo{
            .texture = target_texture,
            .mipLevel = target_resource.mip_level,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = loader.normalizeTextureAspect(model_gpu_types.WGPUTextureAspect_All),
        },
        &copy_extent,
    );
}
