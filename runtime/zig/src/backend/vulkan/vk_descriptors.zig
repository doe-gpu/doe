const std = @import("std");
const c = @import("vk_constants.zig");
const shared = @import("vk_shared_pipeline.zig");
const identity = @import("vk_descriptor_identity.zig");
const cache = @import("vk_pipeline_cache.zig");
const vk_formats = @import("vk_formats.zig");
const vk_resources = @import("vk_resources.zig");
const vk_upload = @import("vk_upload.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const model_texture_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_binding_types = @import("../../contracts/model/model_binding_value_types.zig");
const hash_contract = @import("../../native/vulkan/vulkan_pipeline_hash.zig");

const VK_NULL_U64 = c.VK_NULL_U64;
const compute_descriptor_bindings_hash = hash_contract.compute_descriptor_bindings_hash;
const activate_cached_descriptor_state = cache.activate_cached_descriptor_state;
const stash_active_descriptor_state = cache.stash_active_descriptor_state;
const DescriptorInfoKind = enum { buffer, image };
const PendingDescriptorWrite = struct {
    set_index: u32,
    binding: u32,
    descriptor_type: u32,
    kind: DescriptorInfoKind,
    info_index: usize,
};

pub fn prepare(
    self: anytype,
    bindings: ?[]const model_compute_types.KernelBinding,
    initialize_buffers_on_create: bool,
    precomputed_descriptor_bindings_hash: ?u64,
) !void {
    if (self.descriptor_set_count == 0) return;
    const bs = bindings orelse return error.InvalidArgument;
    const hint = precomputed_descriptor_bindings_hash orelse compute_descriptor_bindings_hash(bs);
    var descriptor_bindings_hash = cache.resolve_descriptor_state_hash(self, hint, bs);
    if (self.has_descriptor_pool and self.has_current_descriptor_bindings_hash and descriptor_bindings_hash == self.current_descriptor_bindings_hash) return;
    if (cache.has_cached_descriptor_state(self, descriptor_bindings_hash)) {
        try stash_active_descriptor_state(self);
        std.debug.assert(activate_cached_descriptor_state(self, descriptor_bindings_hash));
        return;
    }
    if (!self.recorded_submit_replay_active and (self.has_deferred_submissions or self.pending_uploads.items.len > 0)) {
        _ = try vk_upload.flush_queue(self);
    }
    var buffer_infos = std.ArrayListUnmanaged(c.VkDescriptorBufferInfo){};
    defer buffer_infos.deinit(self.allocator);
    var image_infos = std.ArrayListUnmanaged(c.VkDescriptorImageInfo){};
    defer image_infos.deinit(self.allocator);
    var retired_promoted_buffers = std.ArrayListUnmanaged(vk_resources.ComputeBuffer){};
    defer {
        for (retired_promoted_buffers.items) |buffer| {
            vk_resources.release_compute_buffer(self, buffer);
        }
        retired_promoted_buffers.deinit(self.allocator);
    }
    var pending_writes = std.ArrayListUnmanaged(PendingDescriptorWrite){};
    defer pending_writes.deinit(self.allocator);
    var writes = std.ArrayListUnmanaged(c.VkWriteDescriptorSet){};
    defer writes.deinit(self.allocator);

    try buffer_infos.ensureTotalCapacity(self.allocator, bs.len);
    try image_infos.ensureTotalCapacity(self.allocator, bs.len);
    try retired_promoted_buffers.ensureTotalCapacity(self.allocator, bs.len);
    try pending_writes.ensureTotalCapacity(self.allocator, bs.len);
    try writes.ensureTotalCapacity(self.allocator, bs.len);
    const retained = try self.allocator.alloc(identity.Binding, bs.len);
    var retained_owned = true;
    defer if (retained_owned) self.allocator.free(retained);

    // Resolve aliases and final extents before retaining any native handles.
    for (bs) |binding| {
        if (binding.group >= self.descriptor_set_count) return error.InvalidArgument;
        _ = try descriptor_type_for_binding(binding);
        switch (binding.resource_kind) {
            .buffer => {
                const promotion = try vk_resources.ensure_compute_buffer_for_binding(self, binding, initialize_buffers_on_create);
                if (promotion.retired_source) |source| retired_promoted_buffers.appendAssumeCapacity(source);
            },
            .texture, .storage_texture => {
                const texture = self.textures.getPtr(binding.resource_handle) orelse return error.InvalidState;
                _ = try identity.snapshot(self, binding);
                try validate_texture_binding(binding, texture.*);
                try vk_resources.ensure_texture_shader_layout(self, texture);
            },
            .sampler => if (!self.samplers.contains(binding.resource_handle)) return error.InvalidState,
        }
    }
    for (bs, retained) |binding, *resource_identity| {
        resource_identity.* = try identity.snapshot(self, binding);
        const descriptor_type = try descriptor_type_for_binding(binding);
        switch (binding.resource_kind) {
            .buffer => {
                const buffer = self.compute_buffers.get(binding.resource_handle) orelse return error.InvalidState;
                buffer_infos.appendAssumeCapacity(.{
                    .buffer = buffer.buffer,
                    .offset = binding.buffer_offset,
                    .range = try descriptor_range(binding, buffer.size),
                });
                pending_writes.appendAssumeCapacity(.{
                    .set_index = binding.group,
                    .binding = binding.binding,
                    .descriptor_type = descriptor_type,
                    .kind = .buffer,
                    .info_index = buffer_infos.items.len - 1,
                });
            },
            .texture, .storage_texture => {
                const texture = self.textures.get(binding.resource_handle) orelse return error.InvalidState;
                image_infos.appendAssumeCapacity(.{ .sampler = 0, .imageView = texture.view, .imageLayout = texture.layout });
                pending_writes.appendAssumeCapacity(.{
                    .set_index = binding.group,
                    .binding = binding.binding,
                    .descriptor_type = descriptor_type,
                    .kind = .image,
                    .info_index = image_infos.items.len - 1,
                });
            },
            .sampler => {
                const sampler = self.samplers.get(binding.resource_handle) orelse return error.InvalidState;
                image_infos.appendAssumeCapacity(.{ .sampler = sampler.handle, .imageView = VK_NULL_U64, .imageLayout = 0 });
                pending_writes.appendAssumeCapacity(.{
                    .set_index = binding.group,
                    .binding = binding.binding,
                    .descriptor_type = descriptor_type,
                    .kind = .image,
                    .info_index = image_infos.items.len - 1,
                });
            },
        }
    }
    descriptor_bindings_hash = cache.resolve_descriptor_state_hash(self, hint, bs);
    if (self.has_descriptor_pool and self.has_current_descriptor_bindings_hash and descriptor_bindings_hash == self.current_descriptor_bindings_hash) return;
    const previous_key: ?u64 = if (self.has_descriptor_pool and self.has_current_descriptor_bindings_hash) self.current_descriptor_bindings_hash else null;
    try stash_active_descriptor_state(self);
    if (activate_cached_descriptor_state(self, descriptor_bindings_hash)) return;
    errdefer {
        cache.destroy_active_descriptor_pool(self);
        if (previous_key) |key| std.debug.assert(activate_cached_descriptor_state(self, key));
    }
    try ensure_descriptor_pool(self, bindings);

    for (pending_writes.items) |pending| {
        writes.appendAssumeCapacity(.{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.descriptor_sets[@intCast(pending.set_index)],
            .dstBinding = pending.binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = pending.descriptor_type,
            .pImageInfo = if (pending.kind == .image) @ptrCast(&image_infos.items[pending.info_index]) else null,
            .pBufferInfo = if (pending.kind == .buffer) @ptrCast(&buffer_infos.items[pending.info_index]) else null,
            .pTexelBufferView = null,
        });
    }

    if (writes.items.len > 0) {
        c.vkUpdateDescriptorSets(self.device, @intCast(writes.items.len), writes.items.ptr, 0, null);
    }
    self.current_descriptor_identity = retained;
    retained_owned = false;
    self.has_bound_descriptor_bindings_hash = false;
    self.current_descriptor_bindings_hash = descriptor_bindings_hash;
    self.has_current_descriptor_bindings_hash = true;
}

fn ensure_descriptor_pool(self: anytype, bindings: ?[]const model_compute_types.KernelBinding) !void {
    if (self.has_descriptor_pool) return;
    if (self.descriptor_set_count == 0) return;

    var uniform_count: u32 = 0;
    var storage_count: u32 = 0;
    var sampled_image_count: u32 = 0;
    var storage_image_count: u32 = 0;
    var sampler_count: u32 = 0;
    if (bindings) |bs| {
        for (bs) |binding| {
            switch (try descriptor_type_for_binding(binding)) {
                c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER => uniform_count += 1,
                c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER => storage_count += 1,
                c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE => sampled_image_count += 1,
                c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE => storage_image_count += 1,
                c.VK_DESCRIPTOR_TYPE_SAMPLER => sampler_count += 1,
                else => return error.UnsupportedFeature,
            }
        }
    }

    var pool_sizes: [5]c.VkDescriptorPoolSize = undefined;
    var pool_size_count: usize = 0;
    if (uniform_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = uniform_count };
        pool_size_count += 1;
    }
    if (storage_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = storage_count };
        pool_size_count += 1;
    }
    if (sampled_image_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = sampled_image_count };
        pool_size_count += 1;
    }
    if (storage_image_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = storage_image_count };
        pool_size_count += 1;
    }
    if (sampler_count > 0) {
        pool_sizes[pool_size_count] = .{ .type = c.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = sampler_count };
        pool_size_count += 1;
    }

    var pool_info = c.VkDescriptorPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = self.descriptor_set_count,
        .poolSizeCount = @intCast(pool_size_count),
        .pPoolSizes = if (pool_size_count > 0) pool_sizes[0..pool_size_count].ptr else null,
    };
    try c.check_vk(c.vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool));
    errdefer {
        c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
        self.descriptor_pool = VK_NULL_U64;
    }

    var alloc_info = c.VkDescriptorSetAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = self.descriptor_set_count,
        .pSetLayouts = self.descriptor_set_layouts[0..@intCast(self.descriptor_set_count)].ptr,
    };
    try c.check_vk(c.vkAllocateDescriptorSets(self.device, &alloc_info, self.descriptor_sets[0..@intCast(self.descriptor_set_count)].ptr));
    self.has_descriptor_pool = true;
}

// --- Pure helpers ---

pub const descriptor_type_for_binding = shared.descriptorType;

pub fn validate_texture_binding(binding: model_compute_types.KernelBinding, texture: vk_resources.TextureResource) !void {
    if (binding.texture_view_dimension != model_texture_types.WGPUTextureViewDimension_Undefined and
        binding.texture_view_dimension != texture.view_dimension) return error.InvalidState;
    if (binding.texture_multisampled != (texture.sample_count > 1)) return error.InvalidState;
    try validate_texture_binding_aspect(binding.texture_aspect, texture);
    if (binding.texture_format != model_texture_types.WGPUTextureFormat_Undefined and
        binding.texture_format != texture.format) return error.InvalidState;

    switch (binding.resource_kind) {
        .buffer, .sampler => return error.InvalidArgument,
        .texture => {
            if ((texture.usage & model_texture_types.WGPUTextureUsage_TextureBinding) == 0) return error.InvalidState;
            switch (binding.texture_sample_type) {
                model_binding_types.WGPUTextureSampleType_Undefined,
                model_binding_types.WGPUTextureSampleType_Float,
                model_binding_types.WGPUTextureSampleType_UnfilterableFloat,
                model_binding_types.WGPUTextureSampleType_Depth,
                model_binding_types.WGPUTextureSampleType_Sint,
                model_binding_types.WGPUTextureSampleType_Uint,
                => {},
                else => return error.UnsupportedFeature,
            }
        },
        .storage_texture => {
            if ((texture.usage & model_texture_types.WGPUTextureUsage_StorageBinding) == 0) return error.InvalidState;
            switch (binding.storage_texture_access) {
                model_binding_types.WGPUStorageTextureAccess_Undefined,
                model_binding_types.WGPUStorageTextureAccess_WriteOnly,
                model_binding_types.WGPUStorageTextureAccess_ReadOnly,
                model_binding_types.WGPUStorageTextureAccess_ReadWrite,
                => {},
                else => return error.UnsupportedFeature,
            }
        },
    }
}

fn validate_texture_binding_aspect(binding_aspect: u32, texture: vk_resources.TextureResource) !void {
    if (binding_aspect == model_texture_types.WGPUTextureAspect_Undefined or
        binding_aspect == model_texture_types.WGPUTextureAspect_All) return;

    const full_mask = vk_formats.aspect_mask_for_format(texture.format);
    const requested_mask = switch (binding_aspect) {
        model_texture_types.WGPUTextureAspect_DepthOnly => vk_formats.VK_IMAGE_ASPECT_DEPTH_BIT,
        model_texture_types.WGPUTextureAspect_StencilOnly => vk_formats.VK_IMAGE_ASPECT_STENCIL_BIT,
        else => return error.UnsupportedFeature,
    };
    if (requested_mask != full_mask) return error.UnsupportedFeature;
}

pub fn descriptor_range(binding: model_compute_types.KernelBinding, buffer_size: u64) !u64 {
    if (binding.resource_kind != .buffer) return error.UnsupportedFeature;
    if (binding.buffer_size == model_texture_types.WGPUWholeSize) {
        if (binding.buffer_offset > buffer_size) return error.InvalidArgument;
        return c.VK_WHOLE_SIZE;
    }
    if (binding.buffer_size == 0) return error.InvalidArgument;
    const end = std.math.add(u64, binding.buffer_offset, binding.buffer_size) catch return error.InvalidArgument;
    if (end > buffer_size) return error.InvalidArgument;
    return binding.buffer_size;
}

test "validate_texture_binding accepts matching array texture metadata" {
    const binding = model_compute_types.KernelBinding{
        .binding = 0,
        .resource_kind = .texture,
        .resource_handle = 1,
        .texture_view_dimension = model_texture_types.WGPUTextureViewDimension_2DArray,
        .texture_sample_type = model_binding_types.WGPUTextureSampleType_Float,
    };
    const texture = vk_resources.TextureResource{
        .image = VK_NULL_U64,
        .memory = VK_NULL_U64,
        .view = VK_NULL_U64,
        .width = 32,
        .height = 32,
        .depth_or_array_layers = 4,
        .mip_levels = 1,
        .sample_count = 1,
        .dimension = model_texture_types.WGPUTextureDimension_2D,
        .view_dimension = model_texture_types.WGPUTextureViewDimension_2DArray,
        .aspect = model_texture_types.WGPUTextureAspect_All,
        .format = model_texture_types.WGPUTextureFormat_RGBA8Unorm,
        .usage = model_texture_types.WGPUTextureUsage_TextureBinding,
        .layout = 0,
    };
    try validate_texture_binding(binding, texture);
}

test "validate_texture_binding rejects multisample mismatch" {
    const binding = model_compute_types.KernelBinding{
        .binding = 0,
        .resource_kind = .texture,
        .resource_handle = 1,
        .texture_multisampled = true,
        .texture_sample_type = model_binding_types.WGPUTextureSampleType_Float,
    };
    const texture = vk_resources.TextureResource{
        .image = VK_NULL_U64,
        .memory = VK_NULL_U64,
        .view = VK_NULL_U64,
        .width = 16,
        .height = 16,
        .depth_or_array_layers = 1,
        .mip_levels = 1,
        .sample_count = 1,
        .dimension = model_texture_types.WGPUTextureDimension_2D,
        .view_dimension = model_texture_types.WGPUTextureViewDimension_2D,
        .aspect = model_texture_types.WGPUTextureAspect_All,
        .format = model_texture_types.WGPUTextureFormat_RGBA8Unorm,
        .usage = model_texture_types.WGPUTextureUsage_TextureBinding,
        .layout = 0,
    };
    try std.testing.expectError(error.InvalidState, validate_texture_binding(binding, texture));
}
