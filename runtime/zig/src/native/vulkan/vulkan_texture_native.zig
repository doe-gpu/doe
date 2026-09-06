const abi_pipeline = @import("../../core/abi/wgpu_pipeline_descriptor_types.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const shared = @import("vulkan_render_shared.zig");

pub fn vulkan_create_texture(dev: *shared.DoeDevice, tex: *shared.DoeTexture, desc: *const abi_pipeline.WGPUTextureDescriptor) bool {
    if (comptime !shared.has_vulkan) return false;
    const rt = shared.get_runtime(dev) orelse {
        shared.deliverInternalError(dev, "doe_vulkan_render_native: device has no Vulkan runtime", .{});
        return false;
    };

    const usage: model_gpu_types.WGPUFlags = @intCast(if (tex.usage != 0) tex.usage else desc.usage);
    const handle: u64 = @intFromPtr(tex);
    const tex_resource = shared.vk_resources.create_texture_resource_full(
        rt,
        desc.size.width,
        desc.size.height,
        desc.size.depthOrArrayLayers,
        desc.mipLevelCount,
        desc.sampleCount,
        desc.dimension,
        model_gpu_types.WGPUTextureViewDimension_Undefined,
        model_gpu_types.WGPUTextureAspect_Undefined,
        desc.format,
        usage,
    ) catch |err| {
        shared.deliverInternalError(dev, "doe_vulkan_render_native: create_texture_resource_full failed: {s}", .{@errorName(err)});
        return false;
    };
    const result = rt.textures.getOrPut(rt.allocator, handle) catch {
        shared.vk_resources.release_texture_resource(rt, tex_resource);
        return false;
    };
    if (result.found_existing) {
        shared.vk_resources.release_texture_resource(rt, result.value_ptr.*);
    }
    result.value_ptr.* = tex_resource;

    tex.vk_id = handle;
    tex.vk_runtime_ref = @ptrCast(rt);
    tex.width = desc.size.width;
    tex.height = desc.size.height;
    tex.format = desc.format;
    tex.dimension = desc.dimension;
    return true;
}

pub fn vulkan_destroy_texture(tex: *shared.DoeTexture) void {
    if (comptime !shared.has_vulkan) return;
    if (tex.vk_id == 0) return;
    const rt_ptr = tex.vk_runtime_ref orelse return;
    const rt: *shared.NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
    if (rt.textures.fetchRemove(tex.vk_id)) |entry| {
        shared.vk_resources.release_texture_resource(rt, entry.value);
    }
    tex.vk_id = 0;
    tex.vk_runtime_ref = null;
}

pub fn vulkan_create_texture_view(tex: *shared.DoeTexture, tv: *shared.DoeTextureView, desc: *const abi_pipeline.WGPUTextureViewDescriptor, swizzle_r: u32, swizzle_g: u32, swizzle_b: u32, swizzle_a: u32) bool {
    if (comptime !shared.has_vulkan) return false;
    if (tex.vk_id == 0) return false;
    const rt_ptr = tex.vk_runtime_ref orelse return false;
    const rt: *shared.NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
    const texture = rt.textures.get(tex.vk_id) orelse return false;
    const resolved_format: model_gpu_types.WGPUTextureFormat = @intCast(if (desc.format != 0) desc.format else tex.format);
    const resolved_dimension = if (desc.dimension != 0) desc.dimension else if (tex.texture_binding_view_dimension != 0) tex.texture_binding_view_dimension else tex.dimension;
    const resolved_mip_level_count = if (desc.mipLevelCount != 0) desc.mipLevelCount else tex.mip_level_count - desc.baseMipLevel;
    const resolved_array_layer_count = if (desc.arrayLayerCount != 0) desc.arrayLayerCount else if (tex.dimension == model_gpu_types.WGPUTextureDimension_3D) 1 else tex.depth_or_array_layers - desc.baseArrayLayer;
    const generation = rt.next_resource_generation() catch return false;
    const vk_view = shared.vk_resources.create_texture_view(
        rt,
        texture,
        resolved_format,
        resolved_dimension,
        desc.baseMipLevel,
        resolved_mip_level_count,
        desc.baseArrayLayer,
        resolved_array_layer_count,
        desc.aspect,
        swizzle_r,
        swizzle_g,
        swizzle_b,
        swizzle_a,
    ) catch {
        return false;
    };
    const key: u64 = vk_view;
    const result = rt.textures.getOrPut(rt.allocator, key) catch {
        shared.vk_resources.release_texture_view_with_device(rt.device, vk_view);
        return false;
    };
    result.value_ptr.* = .{
        .generation = generation,
        .parent_handle = tex.vk_id,
        .parent_generation = texture.generation,
        .image = texture.image,
        .memory = shared.c.VK_NULL_U64,
        .view = vk_view,
        .owns_image = false,
        .owns_memory = false,
        .owns_view = true,
        .width = texture.width,
        .height = texture.height,
        // Layout tracking is image-wide in the Vulkan runtime. Keep the
        // parent image extent here even though `view` selects a narrower
        // subresource range, so barriers issued through a view preserve the
        // same whole-image layout contract as copies and readback.
        .depth_or_array_layers = texture.depth_or_array_layers,
        .mip_levels = texture.mip_levels,
        .sample_count = texture.sample_count,
        .dimension = texture.dimension,
        .view_dimension = @intCast(resolved_dimension),
        .aspect = desc.aspect,
        .format = resolved_format,
        .usage = if (desc.usage != 0) @intCast(desc.usage) else texture.usage,
        .layout = texture.layout,
    };
    tv.handle = @ptrFromInt(vk_view);
    return true;
}

pub fn vulkan_destroy_texture_view(tv: *shared.DoeTextureView) void {
    if (comptime !shared.has_vulkan) return;
    const handle_ptr = tv.handle orelse return;
    const rt_ptr = tv.tex.vk_runtime_ref orelse return;
    const rt: *shared.NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
    const key: u64 = @intFromPtr(handle_ptr);
    if (rt.textures.fetchRemove(key)) |entry| {
        shared.vk_resources.release_texture_view_with_device(rt.device, entry.value.view);
    }
    tv.handle = null;
}
