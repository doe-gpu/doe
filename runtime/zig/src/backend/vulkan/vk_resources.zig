// Buffer, texture, and sampler resource management for the Vulkan backend.
// Handles compute buffer lifecycle, texture creation/destroy/layout transitions, sampler lifecycle, and format helpers.

const std = @import("std");
const c = @import("vk_constants.zig");
const vk_device = @import("vk_device.zig");
const vk_samplers = @import("vk_samplers.zig");
const vk_upload = @import("vk_upload.zig");
const vk_formats = @import("vk_formats.zig");
const model_binding_types = @import("../../contracts/model/model_binding_value_types.zig");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const backend_policy = @import("../backend_policy.zig");
const common_errors = @import("../../contracts/execution.zig");
const common_timing = @import("../common/timing.zig");

const VkBuffer = c.VkBuffer;
const VkDeviceMemory = c.VkDeviceMemory;
const VkImage = c.VkImage;
const VkImageView = c.VkImageView;
const VK_NULL_U64 = c.VK_NULL_U64;
const VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT: u32 = 0x00000020;

pub const DEFAULT_RUNTIME_TEXTURE_USAGE: model_gpu_types.WGPUFlags = model_gpu_types.WGPUTextureUsage_TextureBinding | model_gpu_types.WGPUTextureUsage_StorageBinding | model_gpu_types.WGPUTextureUsage_CopyDst;
pub const REQUIRED_TEXTURE_UPLOAD_USAGE: model_gpu_types.WGPUFlags = model_gpu_types.WGPUTextureUsage_CopyDst;
const DEVICE_LOCAL_STORAGE_PROMOTION_MIN_BYTES: u64 = 16 * 1024;
const BUFFER_WRITE_STAGING_MIN_CAPACITY: u64 = 64 * 1024;

pub const ComputeBufferMemoryKind = enum { host_visible, readback, device_local };

const memory_policy = @import("vk_memory_policy.zig");

pub const ComputeBuffer = struct {
    buffer: VkBuffer,
    memory: VkDeviceMemory,
    mapped: ?*anyopaque,
    size: u64,
    memory_kind: ComputeBufferMemoryKind,
};

pub const ComputeBufferPromotion = struct {
    buffer: ComputeBuffer,
    retired_source: ?ComputeBuffer = null,
};

pub const TextureResource = struct {
    image: VkImage,
    memory: VkDeviceMemory,
    view: VkImageView,
    owns_image: bool = true,
    owns_memory: bool = true,
    owns_view: bool = true,
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
    mip_levels: u32,
    sample_count: u32,
    dimension: u32,
    view_dimension: u32,
    aspect: u32,
    format: model_gpu_types.WGPUTextureFormat,
    usage: model_gpu_types.WGPUFlags,
    layout: u32,
};

const TextureTransitionSource = struct {
    src_access_mask: u32,
    src_stage: u32,
};

fn texture_dimension_to_vk_image_type(dimension: u32) u32 {
    return switch (dimension) {
        model_gpu_types.WGPUTextureDimension_1D => c.VK_IMAGE_TYPE_1D,
        model_gpu_types.WGPUTextureDimension_3D => c.VK_IMAGE_TYPE_3D,
        else => c.VK_IMAGE_TYPE_2D,
    };
}

fn texture_view_dimension_to_vk_view_type(dimension: u32, array_layers: u32) u32 {
    return switch (dimension) {
        model_gpu_types.WGPUTextureViewDimension_1D => c.VK_IMAGE_VIEW_TYPE_1D,
        model_gpu_types.WGPUTextureViewDimension_2D => c.VK_IMAGE_VIEW_TYPE_2D,
        model_gpu_types.WGPUTextureViewDimension_2DArray => c.VK_IMAGE_VIEW_TYPE_2D_ARRAY,
        model_gpu_types.WGPUTextureViewDimension_Cube => c.VK_IMAGE_VIEW_TYPE_CUBE,
        model_gpu_types.WGPUTextureViewDimension_CubeArray => c.VK_IMAGE_VIEW_TYPE_CUBE_ARRAY,
        model_gpu_types.WGPUTextureViewDimension_3D => c.VK_IMAGE_VIEW_TYPE_3D,
        else => if (array_layers > 1) c.VK_IMAGE_VIEW_TYPE_2D_ARRAY else c.VK_IMAGE_VIEW_TYPE_2D,
    };
}

fn default_texture_view_dimension(dimension: u32, depth_or_array_layers: u32) u32 {
    return switch (dimension) {
        model_gpu_types.WGPUTextureDimension_1D => model_gpu_types.WGPUTextureViewDimension_1D,
        model_gpu_types.WGPUTextureDimension_3D => model_gpu_types.WGPUTextureViewDimension_3D,
        else => if (depth_or_array_layers > 1)
            model_gpu_types.WGPUTextureViewDimension_2DArray
        else
            model_gpu_types.WGPUTextureViewDimension_2D,
    };
}

fn default_texture_view_layer_count(view_dimension: u32, depth_or_array_layers: u32) u32 {
    return switch (view_dimension) {
        model_gpu_types.WGPUTextureViewDimension_2DArray,
        model_gpu_types.WGPUTextureViewDimension_Cube,
        model_gpu_types.WGPUTextureViewDimension_CubeArray,
        => if (depth_or_array_layers > 0) depth_or_array_layers else 1,
        else => 1,
    };
}

fn texture_sample_count_to_vk(sample_count: u32) !u32 {
    return switch (sample_count) {
        0, 1 => c.VK_SAMPLE_COUNT_1_BIT,
        2 => c.VK_SAMPLE_COUNT_2_BIT,
        4 => c.VK_SAMPLE_COUNT_4_BIT,
        8 => c.VK_SAMPLE_COUNT_8_BIT,
        16 => c.VK_SAMPLE_COUNT_16_BIT,
        else => error.UnsupportedFeature,
    };
}

fn texture_view_aspect_mask(format: model_gpu_types.WGPUTextureFormat, aspect: u32) u32 {
    return switch (aspect) {
        model_gpu_types.WGPUTextureAspect_DepthOnly => vk_formats.VK_IMAGE_ASPECT_DEPTH_BIT,
        model_gpu_types.WGPUTextureAspect_StencilOnly => vk_formats.VK_IMAGE_ASPECT_STENCIL_BIT,
        else => vk_formats.aspect_mask_for_format(format),
    };
}

fn texture_component_swizzle_to_vk(component: u32, identity_component: u32) u32 {
    return switch (component) {
        0 => identity_component,
        1 => c.VK_COMPONENT_SWIZZLE_ZERO,
        2 => c.VK_COMPONENT_SWIZZLE_ONE,
        3 => c.VK_COMPONENT_SWIZZLE_R,
        4 => c.VK_COMPONENT_SWIZZLE_G,
        5 => c.VK_COMPONENT_SWIZZLE_B,
        6 => c.VK_COMPONENT_SWIZZLE_A,
        else => identity_component,
    };
}

pub fn ensure_compute_buffer(
    self: anytype,
    handle: u64,
    required_size: u64,
    initialize_buffers_on_create: bool,
) !ComputeBuffer {
    if (handle == 0 or required_size == 0) return error.InvalidArgument;
    if (self.compute_buffers.getPtr(handle)) |existing| {
        if (existing.size >= required_size) return existing.*;
        _ = try vk_upload.flush_queue(self);
        const replacement = try create_compute_buffer_with_kind(
            self,
            required_size,
            initialize_buffers_on_create,
            existing.memory_kind,
        );
        const previous = existing.*;
        existing.* = replacement;
        release_compute_buffer(self, previous);
        return existing.*;
    }
    return insert_compute_buffer(self, handle, required_size, initialize_buffers_on_create, .host_visible);
}

fn insert_compute_buffer(self: anytype, handle: u64, bytes: u64, initialize: bool, kind: ComputeBufferMemoryKind) !ComputeBuffer {
    if (handle == 0 or bytes == 0) return error.InvalidArgument;
    // Initialization can enqueue GPU work. Reserve its owner before creating
    // the allocation so publication cannot fail after that command is recorded.
    try self.compute_buffers.ensureUnusedCapacity(self.allocator, 1);
    const buffer = try create_compute_buffer_with_kind(self, bytes, initialize, kind);
    self.compute_buffers.putAssumeCapacityNoClobber(handle, buffer);
    return buffer;
}

pub fn ensure_compute_buffer_for_binding(
    self: anytype,
    binding: model_compute_types.KernelBinding,
    initialize_buffers_on_create: bool,
) !ComputeBufferPromotion {
    if (binding.resource_kind != .buffer) return error.UnsupportedFeature;
    const required_size = try required_compute_buffer_size(self, binding);
    const desired_memory_kind = compute_buffer_memory_kind_for_binding(binding, required_size);
    const compute_buffer = if (self.compute_buffers.get(binding.resource_handle) == null and desired_memory_kind == .device_local) blk: {
        break :blk try insert_compute_buffer(self, binding.resource_handle, required_size, initialize_buffers_on_create, .device_local);
    } else try ensure_compute_buffer(self, binding.resource_handle, required_size, initialize_buffers_on_create);
    if (compute_buffer_memory_kind_for_binding(binding, required_size) != .device_local or
        compute_buffer.memory_kind == .device_local)
    {
        return .{ .buffer = compute_buffer };
    }
    return try promote_compute_buffer_to_device_local(self, binding.resource_handle);
}

pub fn required_compute_buffer_size(
    self: anytype,
    binding: model_compute_types.KernelBinding,
) !u64 {
    if (binding.resource_kind != .buffer) return error.UnsupportedFeature;
    if (binding.buffer_size == model_gpu_types.WGPUWholeSize) {
        if (self.compute_buffers.get(binding.resource_handle)) |existing| {
            return existing.size;
        }
        return error.InvalidArgument;
    }
    return std.math.add(u64, binding.buffer_offset, binding.buffer_size) catch error.InvalidArgument;
}

pub fn create_compute_buffer(
    self: anytype,
    bytes: u64,
    initialize_buffers_on_create: bool,
) !ComputeBuffer {
    return create_compute_buffer_with_kind(self, bytes, initialize_buffers_on_create, .host_visible);
}

pub fn create_readback_buffer(self: anytype, bytes: u64, initialize_buffers_on_create: bool) !ComputeBuffer {
    return create_compute_buffer_with_kind(self, bytes, initialize_buffers_on_create, .readback);
}

fn create_compute_buffer_with_kind(
    self: anytype,
    bytes: u64,
    initialize_buffers_on_create: bool,
    memory_kind: ComputeBufferMemoryKind,
) !ComputeBuffer {
    var buffer: VkBuffer = VK_NULL_U64;
    var memory: VkDeviceMemory = VK_NULL_U64;
    var mapped: ?*anyopaque = null;

    var buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = bytes,
        .usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT |
            c.VK_BUFFER_USAGE_TRANSFER_DST_BIT |
            c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT |
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT |
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    try c.check_vk(c.vkCreateBuffer(self.device, &buffer_info, null, &buffer));
    errdefer if (buffer != VK_NULL_U64) c.vkDestroyBuffer(self.device, buffer, null);

    var requirements = std.mem.zeroes(c.VkMemoryRequirements);
    c.vkGetBufferMemoryRequirements(self.device, buffer, &requirements);
    const memory_properties = switch (memory_kind) {
        .host_visible => c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        .readback => memory_policy.readback_required_properties,
        .device_local => c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    };
    const memory_index = try vk_device.find_memory_type_index_with_preference(
        self,
        requirements.memoryTypeBits,
        memory_properties,
        if (memory_kind == .readback) memory_policy.readback_preferred_properties else 0,
    );
    var alloc_info = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_index,
    };
    try c.check_vk(c.vkAllocateMemory(self.device, &alloc_info, null, &memory));
    errdefer if (memory != VK_NULL_U64) c.vkFreeMemory(self.device, memory, null);

    try c.check_vk(c.vkBindBufferMemory(self.device, buffer, memory, 0));
    if (memory_kind != .device_local) {
        try c.check_vk(c.vkMapMemory(self.device, memory, 0, bytes, 0, &mapped));
        errdefer if (mapped != null) c.vkUnmapMemory(self.device, memory);

        if (initialize_buffers_on_create and mapped != null) {
            @memset(@as([*]u8, @ptrCast(mapped.?))[0..@intCast(bytes)], 0);
        }
    } else if (initialize_buffers_on_create) {
        if (self.has_deferred_submissions or self.hot_pending_upload != null or self.pending_uploads.items.len > 0) {
            _ = try vk_upload.flush_queue(self);
        }
        try vk_device.ensure_submission_state(self);
        try vk_upload.streaming_fill_buffer(self, buffer, 0, bytes, 0);
    }

    return .{
        .buffer = buffer,
        .memory = memory,
        .mapped = mapped,
        .size = bytes,
        .memory_kind = memory_kind,
    };
}

fn compute_buffer_memory_kind_for_binding(
    binding: model_compute_types.KernelBinding,
    required_size: u64,
) ComputeBufferMemoryKind {
    return switch (binding.buffer_type) {
        model_binding_types.WGPUBufferBindingType_Storage,
        model_binding_types.WGPUBufferBindingType_ReadOnlyStorage,
        => if (required_size < DEVICE_LOCAL_STORAGE_PROMOTION_MIN_BYTES) .host_visible else .device_local,
        else => .host_visible,
    };
}

pub fn promote_compute_buffer_to_device_local(
    self: anytype,
    handle: u64,
) !ComputeBufferPromotion {
    const existing = self.compute_buffers.getPtr(handle) orelse return error.InvalidArgument;
    if (existing.memory_kind == .device_local) return .{ .buffer = existing.* };

    const promoted = try create_compute_buffer_with_kind(self, existing.size, false, .device_local);
    errdefer release_compute_buffer(self, promoted);
    try vk_upload.copy_buffer_region_and_wait(self, existing.buffer, 0, promoted.buffer, 0, existing.size);

    const retired_source = existing.*;
    existing.* = promoted;
    return .{ .buffer = promoted, .retired_source = retired_source };
}

pub fn stage_compute_buffer_write(
    self: anytype,
    compute_buffer: ComputeBuffer,
    offset: u64,
    data_bytes: []const u8,
    upload_path_policy: backend_policy.UploadPathPolicy,
) !void {
    if (data_bytes.len == 0) return error.InvalidArgument;
    const end = std.math.add(u64, offset, data_bytes.len) catch return error.InvalidArgument;
    if (end > compute_buffer.size) return error.InvalidArgument;

    if (self.replay_recording_active) {
        try self.submit_recorded_replay();
    }

    const has_unsubmitted_upload =
        self.hot_pending_upload != null or
        self.pending_uploads.items.len > 0;
    if (has_unsubmitted_upload) {
        _ = try vk_upload.flush_queue(self);
    }

    const queue_has_pending_work =
        self.has_deferred_submissions or
        self.streaming_copy_active or
        self.streaming_copy_pending_count != 0 or
        self.replay_prefix_copy_pending;

    if (upload_path_policy == .allow_mapped_shortcuts and compute_buffer.memory_kind != .device_local and !queue_has_pending_work) {
        const mapped = compute_buffer.mapped orelse return error.InvalidState;
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[@intCast(offset)..][0..data_bytes.len], data_bytes);
        return;
    }

    const staging_offset = self.buffer_write_staging_offset;
    const staging = try ensure_buffer_write_staging_buffer(self, staging_offset + data_bytes.len);
    const mapped = staging.mapped orelse return error.InvalidState;
    @memcpy(@as([*]u8, @ptrCast(mapped))[@intCast(staging_offset)..][0..data_bytes.len], data_bytes);
    try vk_upload.streaming_copy_buffer_region(self, staging.buffer, staging_offset, compute_buffer.buffer, offset, data_bytes.len);
    self.buffer_write_staging_offset = staging_offset + data_bytes.len;
}

fn ensure_buffer_write_staging_buffer(self: anytype, required_bytes: u64) !ComputeBuffer {
    if (required_bytes == 0) return error.InvalidArgument;
    if (self.buffer_write_staging_buffer) |buffer| {
        if (self.buffer_write_staging_capacity >= required_bytes) return buffer;
        if (self.streaming_copy_active) try self.flush_streaming_copy(true);
        if (self.streaming_copy_pending_count != 0 or self.replay_prefix_copy_pending or self.has_deferred_submissions) {
            _ = try vk_upload.flush_queue(self);
        }
        destroy_host_visible_buffer(self, buffer);
        self.buffer_write_staging_buffer = null;
        self.buffer_write_staging_capacity = 0;
    }
    const rounded_capacity = std.math.ceilPowerOfTwo(u64, required_bytes) catch required_bytes;
    const capacity = @max(rounded_capacity, BUFFER_WRITE_STAGING_MIN_CAPACITY);
    const staging = try create_host_visible_buffer(self, capacity, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    self.buffer_write_staging_buffer = staging;
    self.buffer_write_staging_capacity = capacity;
    self.buffer_write_staging_offset = 0;
    return staging;
}

pub fn capture_compute_buffer(
    self: anytype,
    allocator: std.mem.Allocator,
    compute_buffer: ComputeBuffer,
    offset: u64,
    size: u64,
) ![]u8 {
    const end = std.math.add(u64, offset, size) catch return error.InvalidArgument;
    if (size == 0 or end > compute_buffer.size) return error.InvalidArgument;

    if (compute_buffer.memory_kind != .device_local) {
        const mapped = compute_buffer.mapped orelse return error.InvalidState;
        const source = @as([*]u8, @ptrCast(mapped))[@intCast(offset)..@intCast(end)];
        return try allocator.dupe(u8, source);
    }

    const readback = try create_host_visible_buffer(self, size, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    defer destroy_host_visible_buffer(self, readback);
    try vk_upload.copy_buffer_region_and_wait(
        self,
        compute_buffer.buffer,
        offset,
        readback.buffer,
        0,
        size,
    );
    const mapped = readback.mapped orelse return error.InvalidState;
    return try allocator.dupe(u8, @as([*]u8, @ptrCast(mapped))[0..@intCast(size)]);
}

pub fn release_compute_buffer(self: anytype, compute_buffer: ComputeBuffer) void {
    if (compute_buffer.mapped != null) {
        c.vkUnmapMemory(self.device, compute_buffer.memory);
    }
    c.vkDestroyBuffer(self.device, compute_buffer.buffer, null);
    c.vkFreeMemory(self.device, compute_buffer.memory, null);
}

pub fn release_compute_buffers(self: anytype) void {
    var iterator = self.compute_buffers.valueIterator();
    while (iterator.next()) |buffer| {
        release_compute_buffer(self, buffer.*);
    }
    self.compute_buffers.deinit(self.allocator);
}

pub fn create_host_visible_buffer(self: anytype, bytes: u64, usage: u32) !ComputeBuffer {
    var buffer: VkBuffer = VK_NULL_U64;
    var memory: VkDeviceMemory = VK_NULL_U64;
    var mapped: ?*anyopaque = null;

    var buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = bytes,
        .usage = usage,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    try c.check_vk(c.vkCreateBuffer(self.device, &buffer_info, null, &buffer));
    errdefer if (buffer != VK_NULL_U64) c.vkDestroyBuffer(self.device, buffer, null);

    var requirements = std.mem.zeroes(c.VkMemoryRequirements);
    c.vkGetBufferMemoryRequirements(self.device, buffer, &requirements);
    const memory_index = try vk_device.find_memory_type_index(
        self,
        requirements.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    );
    var alloc_info = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_index,
    };
    try c.check_vk(c.vkAllocateMemory(self.device, &alloc_info, null, &memory));
    errdefer if (memory != VK_NULL_U64) c.vkFreeMemory(self.device, memory, null);

    try c.check_vk(c.vkBindBufferMemory(self.device, buffer, memory, 0));
    try c.check_vk(c.vkMapMemory(self.device, memory, 0, bytes, 0, &mapped));
    errdefer if (mapped != null) c.vkUnmapMemory(self.device, memory);

    return .{
        .buffer = buffer,
        .memory = memory,
        .mapped = mapped,
        .size = bytes,
        .memory_kind = .host_visible,
    };
}

pub fn destroy_host_visible_buffer(self: anytype, buffer: ComputeBuffer) void {
    release_compute_buffer(self, buffer);
}

pub fn create_destroy_lifecycle_buffer(self: anytype, bytes: u64) !void {
    var buffer: VkBuffer = VK_NULL_U64;
    var memory: VkDeviceMemory = VK_NULL_U64;
    var buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = bytes,
        .usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    try c.check_vk(c.vkCreateBuffer(self.device, &buffer_info, null, &buffer));
    defer if (buffer != VK_NULL_U64) c.vkDestroyBuffer(self.device, buffer, null);

    var requirements = std.mem.zeroes(c.VkMemoryRequirements);
    c.vkGetBufferMemoryRequirements(self.device, buffer, &requirements);
    const memory_index = try vk_device.find_memory_type_index(
        self,
        requirements.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    );
    var alloc_info = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_index,
    };
    try c.check_vk(c.vkAllocateMemory(self.device, &alloc_info, null, &memory));
    defer if (memory != VK_NULL_U64) c.vkFreeMemory(self.device, memory, null);
    try c.check_vk(c.vkBindBufferMemory(self.device, buffer, memory, 0));
}

// --- Texture resource management ---

pub fn ensure_texture_resource(self: anytype, texture: model_resource_types.CopyTextureResource) !*TextureResource {
    if (texture.handle == 0) return error.InvalidArgument;
    if (texture.width == 0 or texture.height == 0) return error.InvalidArgument;
    const mip_levels: u32 = if (texture.mip_level > 0) texture.mip_level + 1 else 1;
    if (self.textures.getPtr(texture.handle)) |existing| {
        if (existing.width == texture.width and
            existing.height == texture.height and
            existing.depth_or_array_layers == normalized_texture_layer_count(texture.depth_or_array_layers) and
            existing.mip_levels == mip_levels and
            existing.sample_count == normalized_texture_sample_count(texture.sample_count) and
            existing.dimension == normalized_texture_dimension(texture.dimension) and
            existing.view_dimension == normalized_texture_view_dimension(texture.dimension, texture.view_dimension, texture.depth_or_array_layers) and
            existing.aspect == normalized_texture_aspect(texture.aspect) and
            existing.format == texture.format and
            existing.usage == texture.usage)
        {
            return existing;
        }
        if (self.has_deferred_submissions) _ = try vk_upload.flush_queue(self);
        release_texture_resource(self, existing.*);
        existing.* = try create_texture_resource(self, texture, mip_levels);
        return existing;
    }

    try self.textures.put(self.allocator, texture.handle, try create_texture_resource(self, texture, mip_levels));
    return self.textures.getPtr(texture.handle).?;
}

pub fn ensure_texture_shader_layout(self: anytype, texture: *TextureResource) !void {
    if (texture.layout == c.VK_IMAGE_LAYOUT_GENERAL) return;
    if (self.has_deferred_submissions or self.pending_uploads.items.len > 0) {
        _ = try vk_upload.flush_queue(self);
    }
    try vk_device.ensure_submission_state(self);

    try c.check_vk(c.vkResetCommandPool(self.device, self.command_pool, 0));
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try c.check_vk(c.vkBeginCommandBuffer(self.primary_command_buffer, &begin_info));
    const source = texture_transition_source(texture.layout);
    transition_texture_layout(
        self.primary_command_buffer,
        texture.*,
        texture.layout,
        c.VK_IMAGE_LAYOUT_GENERAL,
        source.src_access_mask,
        c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
        source.src_stage,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    );
    try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));

    var submit_info = c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = @ptrCast(&self.primary_command_buffer),
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };
    try c.check_vk(c.vkResetFences(self.device, 1, @ptrCast(&self.fence)));
    try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), self.fence));
    try c.check_vk(c.vkWaitForFences(self.device, 1, @ptrCast(&self.fence), c.VK_TRUE, vk_upload.WAIT_TIMEOUT_NS));
    mark_texture_image_layout(self, texture.image, c.VK_IMAGE_LAYOUT_GENERAL);
}

pub fn mark_texture_image_layout(self: anytype, image: c.VkImage, layout: u32) void {
    var iterator = self.textures.valueIterator();
    while (iterator.next()) |texture| {
        if (texture.image == image) texture.layout = layout;
    }
}

pub fn create_texture_resource(
    self: anytype,
    texture: model_resource_types.CopyTextureResource,
    mip_levels: u32,
) !TextureResource {
    const resolved_dimension = normalized_texture_dimension(texture.dimension);
    const resolved_layer_count = normalized_texture_layer_count(texture.depth_or_array_layers);
    return create_texture_resource_full(
        self,
        texture.width,
        texture.height,
        resolved_layer_count,
        mip_levels,
        normalized_texture_sample_count(texture.sample_count),
        resolved_dimension,
        normalized_texture_view_dimension(resolved_dimension, texture.view_dimension, texture.depth_or_array_layers),
        normalized_texture_aspect(texture.aspect),
        texture.format,
        texture.usage,
    );
}

pub fn create_texture_resource_full(
    self: anytype,
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
    mip_levels: u32,
    sample_count: u32,
    dimension: u32,
    view_dimension: u32,
    aspect: u32,
    format: model_gpu_types.WGPUTextureFormat,
    usage: model_gpu_types.WGPUFlags,
) !TextureResource {
    var image: VkImage = VK_NULL_U64;
    var memory: VkDeviceMemory = VK_NULL_U64;
    var view: VkImageView = VK_NULL_U64;
    const effective_usage = effective_texture_usage(usage);
    const layers = if (depth_or_array_layers > 0) depth_or_array_layers else 1;
    const resolved_mip_levels = if (mip_levels > 0) mip_levels else 1;
    const resolved_dimension = if (dimension != 0) dimension else model_gpu_types.WGPUTextureDimension_2D;
    const resolved_view_dimension = if (view_dimension != 0) view_dimension else default_texture_view_dimension(resolved_dimension, layers);
    const resolved_aspect = if (aspect != 0) aspect else model_gpu_types.WGPUTextureAspect_All;
    const image_type = texture_dimension_to_vk_image_type(resolved_dimension);
    const image_depth: u32 = if (resolved_dimension == model_gpu_types.WGPUTextureDimension_3D) layers else 1;
    const image_array_layers: u32 = if (resolved_dimension == model_gpu_types.WGPUTextureDimension_3D) 1 else layers;
    const sample_count_vk = try texture_sample_count_to_vk(sample_count);
    const view_type = texture_view_dimension_to_vk_view_type(resolved_view_dimension, image_array_layers);

    var image_info = c.VkImageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = if (image_array_layers >= 6 and resolved_dimension == model_gpu_types.WGPUTextureDimension_2D) c.VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT else 0,
        .imageType = image_type,
        .format = try texture_format_to_vk(format),
        .extent = .{ .width = width, .height = height, .depth = image_depth },
        .mipLevels = resolved_mip_levels,
        .arrayLayers = image_array_layers,
        .samples = sample_count_vk,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = image_usage_for_texture(effective_usage, format),
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    try c.check_vk(c.vkCreateImage(self.device, &image_info, null, &image));
    errdefer if (image != VK_NULL_U64) c.vkDestroyImage(self.device, image, null);

    var requirements = std.mem.zeroes(c.VkMemoryRequirements);
    c.vkGetImageMemoryRequirements(self.device, image, &requirements);
    const memory_index = try vk_device.find_memory_type_index(
        self,
        requirements.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    );
    var alloc_info = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_index,
    };
    try c.check_vk(c.vkAllocateMemory(self.device, &alloc_info, null, &memory));
    errdefer if (memory != VK_NULL_U64) c.vkFreeMemory(self.device, memory, null);

    try c.check_vk(c.vkBindImageMemory(self.device, image, memory, 0));

    const aspect_mask = texture_view_aspect_mask(format, resolved_aspect);
    var view_info = c.VkImageViewCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = view_type,
        .format = try texture_format_to_vk(format),
        .components = .{
            .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = aspect_mask,
            .baseMipLevel = 0,
            .levelCount = resolved_mip_levels,
            .baseArrayLayer = 0,
            .layerCount = if (view_type == c.VK_IMAGE_VIEW_TYPE_3D) 1 else image_array_layers,
        },
    };
    try c.check_vk(c.vkCreateImageView(self.device, &view_info, null, &view));
    errdefer if (view != VK_NULL_U64) c.vkDestroyImageView(self.device, view, null);

    return .{
        .image = image,
        .memory = memory,
        .view = view,
        .width = width,
        .height = height,
        .depth_or_array_layers = layers,
        .mip_levels = resolved_mip_levels,
        .sample_count = if (sample_count > 0) sample_count else 1,
        .dimension = resolved_dimension,
        .view_dimension = resolved_view_dimension,
        .aspect = resolved_aspect,
        .format = format,
        .usage = effective_usage,
        .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
}

pub fn borrowed_texture_resource(
    image: VkImage,
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
    mip_levels: u32,
    sample_count: u32,
    dimension: u32,
    view_dimension: u32,
    aspect: u32,
    format: model_gpu_types.WGPUTextureFormat,
    usage: model_gpu_types.WGPUFlags,
    layout: u32,
) TextureResource {
    return .{
        .image = image,
        .memory = VK_NULL_U64,
        .view = VK_NULL_U64,
        .owns_image = false,
        .owns_memory = false,
        .owns_view = false,
        .width = width,
        .height = height,
        .depth_or_array_layers = if (depth_or_array_layers > 0) depth_or_array_layers else 1,
        .mip_levels = if (mip_levels > 0) mip_levels else 1,
        .sample_count = if (sample_count > 0) sample_count else 1,
        .dimension = if (dimension != 0) dimension else model_gpu_types.WGPUTextureDimension_2D,
        .view_dimension = if (view_dimension != 0) view_dimension else model_gpu_types.WGPUTextureViewDimension_2D,
        .aspect = if (aspect != 0) aspect else model_gpu_types.WGPUTextureAspect_All,
        .format = format,
        .usage = effective_texture_usage(usage),
        .layout = layout,
    };
}

pub fn create_texture_view(
    self: anytype,
    texture: TextureResource,
    format: model_gpu_types.WGPUTextureFormat,
    dimension: u32,
    base_mip_level: u32,
    mip_level_count: u32,
    base_array_layer: u32,
    array_layer_count: u32,
    aspect: u32,
    swizzle_r: u32,
    swizzle_g: u32,
    swizzle_b: u32,
    swizzle_a: u32,
) !VkImageView {
    var view: VkImageView = VK_NULL_U64;
    const resolved_format = if (format != 0) format else texture.format;
    const resolved_level_count = if (mip_level_count != 0) mip_level_count else texture.mip_levels - base_mip_level;
    const resolved_view_dimension = if (dimension != 0) dimension else texture.view_dimension;
    const resolved_layer_count = if (array_layer_count != 0)
        array_layer_count
    else
        default_texture_view_layer_count(resolved_view_dimension, texture.depth_or_array_layers);
    const view_type = texture_view_dimension_to_vk_view_type(resolved_view_dimension, resolved_layer_count);
    var view_info = c.VkImageViewCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = texture.image,
        .viewType = view_type,
        .format = try texture_format_to_vk(resolved_format),
        .components = .{
            .r = texture_component_swizzle_to_vk(swizzle_r, c.VK_COMPONENT_SWIZZLE_R),
            .g = texture_component_swizzle_to_vk(swizzle_g, c.VK_COMPONENT_SWIZZLE_G),
            .b = texture_component_swizzle_to_vk(swizzle_b, c.VK_COMPONENT_SWIZZLE_B),
            .a = texture_component_swizzle_to_vk(swizzle_a, c.VK_COMPONENT_SWIZZLE_A),
        },
        .subresourceRange = .{
            .aspectMask = texture_view_aspect_mask(resolved_format, aspect),
            .baseMipLevel = base_mip_level,
            .levelCount = resolved_level_count,
            .baseArrayLayer = base_array_layer,
            .layerCount = if (view_type == c.VK_IMAGE_VIEW_TYPE_3D) 1 else resolved_layer_count,
        },
    };
    try c.check_vk(c.vkCreateImageView(self.device, &view_info, null, &view));
    return view;
}

pub fn release_texture_resource(self: anytype, texture: TextureResource) void {
    release_texture_resource_with_device(self.device, texture);
}

pub fn release_texture_resource_with_device(device: c.VkDevice, texture: TextureResource) void {
    if (texture.owns_view and texture.view != VK_NULL_U64) c.vkDestroyImageView(device, texture.view, null);
    if (texture.owns_image and texture.image != VK_NULL_U64) c.vkDestroyImage(device, texture.image, null);
    if (texture.owns_memory and texture.memory != VK_NULL_U64) c.vkFreeMemory(device, texture.memory, null);
}

pub fn release_texture_view_with_device(device: c.VkDevice, view: VkImageView) void {
    if (view != VK_NULL_U64) c.vkDestroyImageView(device, view, null);
}

pub fn release_textures(self: anytype) void {
    var iterator = self.textures.valueIterator();
    while (iterator.next()) |texture| {
        release_texture_resource(self, texture.*);
    }
    self.textures.deinit(self.allocator);
}

pub fn transition_texture_layout(
    command_buffer: c.VkCommandBuffer,
    texture: TextureResource,
    old_layout: u32,
    new_layout: u32,
    src_access_mask: u32,
    dst_access_mask: u32,
    src_stage: u32,
    dst_stage: u32,
) void {
    var image_barrier = c.VkImageMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = src_access_mask,
        .dstAccessMask = dst_access_mask,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = std.math.maxInt(u32),
        .dstQueueFamilyIndex = std.math.maxInt(u32),
        .image = texture.image,
        .subresourceRange = .{
            .aspectMask = vk_formats.aspect_mask_for_format(texture.format),
            .baseMipLevel = 0,
            .levelCount = texture.mip_levels,
            .baseArrayLayer = 0,
            .layerCount = texture_barrier_layer_count(texture),
        },
    };
    c.vkCmdPipelineBarrier(
        command_buffer,
        src_stage,
        dst_stage,
        0,
        0,
        null,
        0,
        null,
        1,
        @ptrCast(&image_barrier),
    );
}

fn texture_barrier_layer_count(texture: TextureResource) u32 {
    if (texture.view_dimension == model_gpu_types.WGPUTextureViewDimension_3D) return 1;
    return if (texture.depth_or_array_layers > 0) texture.depth_or_array_layers else 1;
}

fn normalized_texture_layer_count(depth_or_array_layers: u32) u32 {
    return if (depth_or_array_layers > 0) depth_or_array_layers else 1;
}

fn normalized_texture_sample_count(sample_count: u32) u32 {
    return if (sample_count > 0) sample_count else 1;
}

fn normalized_texture_dimension(dimension: u32) u32 {
    return if (dimension != 0) dimension else model_gpu_types.WGPUTextureDimension_2D;
}

fn normalized_texture_view_dimension(dimension: u32, view_dimension: u32, depth_or_array_layers: u32) u32 {
    return if (view_dimension != 0)
        view_dimension
    else
        default_texture_view_dimension(normalized_texture_dimension(dimension), normalized_texture_layer_count(depth_or_array_layers));
}

fn normalized_texture_aspect(aspect: u32) u32 {
    return if (aspect != 0) aspect else model_gpu_types.WGPUTextureAspect_All;
}

test "default_texture_view_dimension preserves non-2d resources" {
    try std.testing.expectEqual(
        model_gpu_types.WGPUTextureViewDimension_3D,
        default_texture_view_dimension(model_gpu_types.WGPUTextureDimension_3D, 4),
    );
    try std.testing.expectEqual(
        model_gpu_types.WGPUTextureViewDimension_2DArray,
        default_texture_view_dimension(model_gpu_types.WGPUTextureDimension_2D, 6),
    );
}

// --- Pure texture helpers ---

pub fn texture_transition_source(layout: u32) TextureTransitionSource {
    return switch (layout) {
        c.VK_IMAGE_LAYOUT_UNDEFINED => .{
            .src_access_mask = 0,
            .src_stage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        },
        c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL => .{
            .src_access_mask = c.VK_ACCESS_TRANSFER_READ_BIT,
            .src_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        },
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL => .{
            .src_access_mask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
            .src_stage = c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        },
        c.VK_IMAGE_LAYOUT_GENERAL => .{
            .src_access_mask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
            .src_stage = c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        },
        c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL => .{
            .src_access_mask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .src_stage = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        },
        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL => .{
            .src_access_mask = c.VK_ACCESS_SHADER_READ_BIT,
            .src_stage = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        },
        else => .{
            .src_access_mask = 0,
            .src_stage = c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        },
    };
}

pub fn effective_texture_usage(requested: model_gpu_types.WGPUFlags) model_gpu_types.WGPUFlags {
    if (requested == 0) return DEFAULT_RUNTIME_TEXTURE_USAGE;
    return requested | REQUIRED_TEXTURE_UPLOAD_USAGE;
}

pub fn texture_format_to_vk(format: model_gpu_types.WGPUTextureFormat) !u32 {
    return vk_formats.wgpu_format_to_vk_format(format);
}

pub fn image_usage_for_texture(usage: model_gpu_types.WGPUFlags, format: model_gpu_types.WGPUTextureFormat) u32 {
    var out: u32 = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if ((usage & model_gpu_types.WGPUTextureUsage_TextureBinding) != 0) out |= c.VK_IMAGE_USAGE_SAMPLED_BIT;
    if ((usage & model_gpu_types.WGPUTextureUsage_StorageBinding) != 0) out |= c.VK_IMAGE_USAGE_STORAGE_BIT;
    if ((usage & model_gpu_types.WGPUTextureUsage_CopySrc) != 0) out |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if ((usage & model_gpu_types.WGPUTextureUsage_CopyDst) != 0) out |= c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if ((usage & model_gpu_types.WGPUTextureUsage_RenderAttachment) != 0) {
        out |= if (vk_formats.is_depth_stencil(format))
            VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
        else
            c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    }
    return out;
}

pub fn bytes_per_pixel_for_texture_format(format: model_gpu_types.WGPUTextureFormat) u32 {
    return vk_formats.bytes_per_pixel(format) catch 4;
}

// --- Sampler resource management ---

pub fn create_sampler(self: anytype, cmd: model_render_types.SamplerCreateCommand) !c.VkSampler {
    return vk_samplers.create_sampler(self, cmd);
}

pub fn destroy_sampler(self: anytype, handle: u64) void {
    vk_samplers.destroy_sampler(self, handle);
}

pub fn release_samplers(self: anytype) void {
    vk_samplers.release_samplers(self);
}
