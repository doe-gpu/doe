const std = @import("std");
const identity = @import("vk_descriptor_identity.zig");
const upload = @import("vk_upload.zig");
const c = @import("vk_constants.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");

// WebGPU filter/address mode constants for sampler translation.
const WGPU_FILTER_LINEAR: u32 = 2;
const WGPU_ADDRESS_MODE_REPEAT: u32 = 2;
const WGPU_ADDRESS_MODE_MIRROR_REPEAT: u32 = 3;
const WGPU_COMPARE_FUNCTION_NEVER: u32 = 1;
const WGPU_COMPARE_FUNCTION_LESS: u32 = 2;
const WGPU_COMPARE_FUNCTION_EQUAL: u32 = 3;
const WGPU_COMPARE_FUNCTION_LESS_EQUAL: u32 = 4;
const WGPU_COMPARE_FUNCTION_GREATER: u32 = 5;
const WGPU_COMPARE_FUNCTION_NOT_EQUAL: u32 = 6;
const WGPU_COMPARE_FUNCTION_GREATER_EQUAL: u32 = 7;
const WGPU_COMPARE_FUNCTION_ALWAYS: u32 = 8;
const VK_SAMPLER_ADDRESS_MODE_REPEAT: u32 = 0;
const VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT: u32 = 1;
const VK_FILTER_LINEAR: u32 = 1;
const VK_SAMPLER_MIPMAP_MODE_LINEAR: u32 = 1;
const VK_COMPARE_OP_LESS: u32 = 1;
const VK_COMPARE_OP_EQUAL: u32 = 2;
const VK_COMPARE_OP_LESS_OR_EQUAL: u32 = 3;
const VK_COMPARE_OP_GREATER: u32 = 4;
const VK_COMPARE_OP_NOT_EQUAL: u32 = 5;
const VK_COMPARE_OP_GREATER_OR_EQUAL: u32 = 6;
const VK_COMPARE_OP_ALWAYS: u32 = 7;

fn wgpu_filter_to_vk(filter: u32) u32 {
    return if (filter == WGPU_FILTER_LINEAR) VK_FILTER_LINEAR else c.VK_FILTER_NEAREST;
}

fn wgpu_mipmap_to_vk(filter: u32) u32 {
    return if (filter == WGPU_FILTER_LINEAR) VK_SAMPLER_MIPMAP_MODE_LINEAR else c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
}

fn wgpu_address_to_vk(mode: u32) u32 {
    return switch (mode) {
        WGPU_ADDRESS_MODE_REPEAT => VK_SAMPLER_ADDRESS_MODE_REPEAT,
        WGPU_ADDRESS_MODE_MIRROR_REPEAT => VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT,
        else => c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    };
}

fn wgpu_compare_to_vk(compare: u32) u32 {
    return switch (compare) {
        WGPU_COMPARE_FUNCTION_NEVER => c.VK_COMPARE_OP_NEVER,
        WGPU_COMPARE_FUNCTION_LESS => VK_COMPARE_OP_LESS,
        WGPU_COMPARE_FUNCTION_EQUAL => VK_COMPARE_OP_EQUAL,
        WGPU_COMPARE_FUNCTION_LESS_EQUAL => VK_COMPARE_OP_LESS_OR_EQUAL,
        WGPU_COMPARE_FUNCTION_GREATER => VK_COMPARE_OP_GREATER,
        WGPU_COMPARE_FUNCTION_NOT_EQUAL => VK_COMPARE_OP_NOT_EQUAL,
        WGPU_COMPARE_FUNCTION_GREATER_EQUAL => VK_COMPARE_OP_GREATER_OR_EQUAL,
        WGPU_COMPARE_FUNCTION_ALWAYS => VK_COMPARE_OP_ALWAYS,
        else => VK_COMPARE_OP_ALWAYS,
    };
}

pub fn create_sampler(self: anytype, cmd: model_render_types.SamplerCreateCommand) !c.VkSampler {
    try self.samplers.ensureUnusedCapacity(self.allocator, 1);
    const generation = try identity.nextGeneration(self);
    if (self.samplers.contains(cmd.handle) and self.has_deferred_submissions) _ = try upload.flush_queue(self);
    var create_info = c.VkSamplerCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .magFilter = wgpu_filter_to_vk(cmd.mag_filter),
        .minFilter = wgpu_filter_to_vk(cmd.min_filter),
        .mipmapMode = wgpu_mipmap_to_vk(cmd.mipmap_filter),
        .addressModeU = wgpu_address_to_vk(cmd.address_mode_u),
        .addressModeV = wgpu_address_to_vk(cmd.address_mode_v),
        .addressModeW = wgpu_address_to_vk(cmd.address_mode_w),
        .mipLodBias = 0.0,
        .anisotropyEnable = c.VK_FALSE,
        .maxAnisotropy = @floatFromInt(cmd.max_anisotropy),
        .compareEnable = if (cmd.compare == 0) c.VK_FALSE else c.VK_TRUE,
        .compareOp = if (cmd.compare == 0) c.VK_COMPARE_OP_NEVER else wgpu_compare_to_vk(cmd.compare),
        .minLod = cmd.lod_min_clamp,
        .maxLod = cmd.lod_max_clamp,
        .borderColor = c.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
        .unnormalizedCoordinates = c.VK_FALSE,
    };

    var vk_sampler: c.VkSampler = c.VK_NULL_U64;
    try c.check_vk(c.vkCreateSampler(self.device, &create_info, null, &vk_sampler));

    const gop = self.samplers.getOrPutAssumeCapacity(cmd.handle);
    if (gop.found_existing and gop.value_ptr.handle != c.VK_NULL_U64) {
        c.vkDestroySampler(self.device, gop.value_ptr.handle, null);
    }
    gop.value_ptr.* = .{ .handle = vk_sampler, .generation = generation };
    return vk_sampler;
}

pub fn destroy_sampler(self: anytype, handle: u64) void {
    if (self.samplers.fetchRemove(handle)) |entry| {
        if (entry.value.handle != c.VK_NULL_U64) {
            c.vkDestroySampler(self.device, entry.value.handle, null);
        }
    }
}

pub fn release_samplers(self: anytype) void {
    var iterator = self.samplers.valueIterator();
    while (iterator.next()) |vk_sampler| {
        if (vk_sampler.handle != c.VK_NULL_U64) {
            c.vkDestroySampler(self.device, vk_sampler.handle, null);
        }
    }
    self.samplers.deinit(self.allocator);
}
