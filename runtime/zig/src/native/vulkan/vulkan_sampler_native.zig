const abi_pipeline = @import("../../core/abi/wgpu_pipeline_descriptor_types.zig");
const shared = @import("vulkan_render_shared.zig");

pub fn vulkan_create_sampler(dev: *shared.DoeDevice, sampler: *shared.DoeSampler, desc: *const abi_pipeline.WGPUSamplerDescriptor) bool {
    if (comptime !shared.has_vulkan) return false;
    const rt = shared.get_runtime(dev) orelse {
        shared.deliverInternalError(dev, "doe_vulkan_render_native: device has no Vulkan runtime for sampler", .{});
        return false;
    };

    const generation = rt.next_resource_generation() catch {
        shared.deliverInternalError(dev, "doe_vulkan_render_native: sampler resource generation exhausted", .{});
        return false;
    };
    rt.samplers.ensureUnusedCapacity(rt.allocator, 1) catch {
        shared.deliverInternalError(dev, "doe_vulkan_render_native: sampler map reservation failed", .{});
        return false;
    };
    var create_info = shared.c.VkSamplerCreateInfo{
        .sType = shared.c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .magFilter = shared.wgpu_filter_to_vk(desc.magFilter),
        .minFilter = shared.wgpu_filter_to_vk(desc.minFilter),
        .mipmapMode = shared.wgpu_mipmap_to_vk(desc.mipmapFilter),
        .addressModeU = shared.wgpu_address_to_vk(desc.addressModeU),
        .addressModeV = shared.wgpu_address_to_vk(desc.addressModeV),
        .addressModeW = shared.wgpu_address_to_vk(desc.addressModeW),
        .mipLodBias = 0.0,
        .anisotropyEnable = shared.c.VK_FALSE,
        .maxAnisotropy = 1.0,
        .compareEnable = if (desc.compare != shared.WGPU_COMPARE_UNDEFINED) shared.c.VK_TRUE else shared.c.VK_FALSE,
        .compareOp = if (desc.compare != shared.WGPU_COMPARE_UNDEFINED) shared.wgpu_compare_to_vk(desc.compare) else shared.c.VK_COMPARE_OP_NEVER,
        .minLod = desc.lodMinClamp,
        .maxLod = desc.lodMaxClamp,
        .borderColor = shared.c.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
        .unnormalizedCoordinates = shared.c.VK_FALSE,
    };

    var vk_sampler: shared.c.VkSampler = shared.c.VK_NULL_U64;
    shared.c.check_vk(shared.c.vkCreateSampler(rt.device, &create_info, null, &vk_sampler)) catch |err| {
        shared.deliverInternalError(dev, "doe_vulkan_render_native: vkCreateSampler failed: {s}", .{@errorName(err)});
        return false;
    };

    sampler.mtl = @ptrFromInt(vk_sampler);
    sampler.vk_runtime_ref = @ptrCast(rt);

    const handle: u64 = @intFromPtr(sampler);
    rt.samplers.putAssumeCapacity(handle, .{ .handle = vk_sampler, .generation = generation });
    return true;
}

pub fn vulkan_destroy_sampler(sampler: *shared.DoeSampler, rt: *shared.NativeVulkanRuntime) void {
    if (comptime !shared.has_vulkan) return;
    const handle: u64 = @intFromPtr(sampler);
    _ = rt.samplers.remove(handle);

    if (sampler.mtl) |ptr| {
        const vk_sampler: shared.c.VkSampler = @intFromPtr(ptr);
        if (vk_sampler != shared.c.VK_NULL_U64) {
            shared.c.vkDestroySampler(rt.device, vk_sampler, null);
        }
        sampler.mtl = null;
    }
    sampler.vk_runtime_ref = null;
}
