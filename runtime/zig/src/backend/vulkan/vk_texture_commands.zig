// vk_texture_commands.zig — Texture write, read, copy, query, and destroy
// commands for the NativeVulkanRuntime. Sharded from native_runtime.zig.

const std = @import("std");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const model_texture_types = @import("../../contracts/model/model_texture_types.zig");
const c = @import("vk_constants.zig");
const vk_device = @import("vk_device.zig");
const vk_sync = @import("vk_sync.zig");
const vk_upload = @import("vk_upload.zig");
const vk_resources = @import("vk_resources.zig");
const vk_formats = @import("vk_formats.zig");

const TextureReadExtent = struct {
    width: u32,
    height: u32,
};

fn texture_read_copy_extent(width: u32, height: u32) TextureReadExtent {
    // WebGPU's copy extent is already expressed in the selected mip's
    // coordinate space. Applying the mip shift again truncates readback.
    return .{ .width = width, .height = height };
}

pub const BufferCopy = struct {
    offset: u64,
    bytes_per_row: u32,
    rows_per_image: u32,
    mip: u32,
    width: u32,
    height: u32,
    depth_or_layers: u32,
};

pub fn buffer_copy_region(source_size: u64, texture: vk_resources.TextureResource, copy: BufferCopy) !c.VkBufferImageCopy {
    if (copy.mip >= texture.mip_levels or copy.mip >= @bitSizeOf(u32) or texture.sample_count != 1)
        return error.InvalidArgument;
    if (texture.format == model_gpu_types.WGPUTextureFormat_Depth24Plus or
        texture.format == model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8 or
        texture.format == model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8)
        return error.UnsupportedFeature;
    const shift: u5 = @intCast(copy.mip);
    const mip_width = @max(texture.width >> shift, 1);
    const mip_height = @max(texture.height >> shift, 1);
    const is_3d = texture.dimension == model_gpu_types.WGPUTextureDimension_3D;
    const layers = if (is_3d) @max(texture.depth_or_array_layers >> shift, 1) else texture.depth_or_array_layers;
    if (copy.width > mip_width or copy.height > mip_height or copy.depth_or_layers > layers)
        return error.InvalidArgument;
    const block = vk_formats.copy_block_extent(texture.format);
    const bytes = try vk_formats.bytes_per_pixel(texture.format);
    if ((copy.width % block[0] != 0 and copy.width != mip_width) or
        (copy.height % block[1] != 0 and copy.height != mip_height) or copy.offset % bytes != 0)
        return error.InvalidArgument;
    const columns = std.math.divCeil(u64, copy.width, block[0]) catch unreachable;
    const rows = std.math.divCeil(u64, copy.height, block[1]) catch unreachable;
    const row_bytes = columns * bytes;
    const pitch = if (copy.bytes_per_row == 0) row_bytes else copy.bytes_per_row;
    const image_rows = if (copy.rows_per_image == 0) rows else copy.rows_per_image;
    if (pitch < row_bytes or pitch % bytes != 0 or image_rows < rows) return error.InvalidArgument;
    var required: u64 = 0;
    if (copy.width != 0 and copy.height != 0 and copy.depth_or_layers != 0) {
        const image_stride = try std.math.mul(u64, pitch, image_rows);
        required = try std.math.mul(u64, image_stride, copy.depth_or_layers - 1);
        required = try std.math.add(u64, required, try std.math.mul(u64, pitch, rows - 1));
        required = try std.math.add(u64, required, row_bytes);
    }
    if (copy.offset > source_size or required > source_size - copy.offset) return error.InvalidArgument;
    const row_length = std.math.cast(u32, (pitch / bytes) * block[0]) orelse return error.InvalidArgument;
    const image_height = std.math.cast(u32, image_rows * block[1]) orelse return error.InvalidArgument;
    return .{
        .bufferOffset = copy.offset,
        .bufferRowLength = row_length,
        .bufferImageHeight = image_height,
        .imageSubresource = .{
            .aspectMask = vk_formats.aspect_mask_for_format(texture.format),
            .mipLevel = copy.mip,
            .baseArrayLayer = 0,
            .layerCount = if (is_3d) 1 else copy.depth_or_layers,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = copy.width, .height = copy.height, .depth = if (is_3d) copy.depth_or_layers else 1 },
    };
}

pub fn record_buffer_copy(self: anytype, source: vk_resources.ComputeBuffer, texture: *vk_resources.TextureResource, copy: BufferCopy) !void {
    const region = try buffer_copy_region(source.size, texture.*, copy);
    if (copy.width == 0 or copy.height == 0 or copy.depth_or_layers == 0) return;
    const command_buffer = try self.begin_prepared_dispatch_replay();
    const barrier = c.VkMemoryBarrier{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
    };
    c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 1, @ptrCast(&barrier), 0, null, 0, null);
    vk_resources.transition_texture_layout(command_buffer, texture.*, texture.layout, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_ACCESS_MEMORY_READ_BIT | c.VK_ACCESS_MEMORY_WRITE_BIT, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT);
    c.vkCmdCopyBufferToImage(command_buffer, source.buffer, texture.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @ptrCast(&region));
    vk_resources.transition_texture_layout(command_buffer, texture.*, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_ACCESS_MEMORY_READ_BIT | c.VK_ACCESS_MEMORY_WRITE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT);
    vk_resources.mark_texture_image_layout(self, texture.image, c.VK_IMAGE_LAYOUT_GENERAL);
}

test "buffer image copy validates the last accessed byte and mip-relative layers" {
    var texture = std.mem.zeroes(vk_resources.TextureResource);
    texture.width = 8;
    texture.height = 4;
    texture.depth_or_array_layers = 3;
    texture.mip_levels = 3;
    texture.sample_count = 1;
    texture.dimension = model_gpu_types.WGPUTextureDimension_2D;
    texture.format = model_gpu_types.WGPUTextureFormat_RGBA8Unorm;
    var copy = BufferCopy{ .offset = 16, .bytes_per_row = 256, .rows_per_image = 3, .mip = 1, .width = 4, .height = 2, .depth_or_layers = 2 };
    const minimum_source_size = 16 + 256 * 3 + 256 + 16;
    const region = try buffer_copy_region(minimum_source_size, texture, copy);
    try std.testing.expectEqual(@as(u32, 4), region.imageExtent.width);
    try std.testing.expectEqual(@as(u32, 2), region.imageSubresource.layerCount);
    try std.testing.expectEqual(@as(u32, 1), region.imageExtent.depth);
    try std.testing.expectError(error.InvalidArgument, buffer_copy_region(minimum_source_size - 1, texture, copy));
    copy.width = 5;
    try std.testing.expectError(error.InvalidArgument, buffer_copy_region(minimum_source_size, texture, copy));
    copy.width = 4;
    texture.dimension = model_gpu_types.WGPUTextureDimension_3D;
    try std.testing.expectError(error.InvalidArgument, buffer_copy_region(minimum_source_size, texture, copy));
    texture.depth_or_array_layers = 4;
    const volume = try buffer_copy_region(minimum_source_size, texture, copy);
    try std.testing.expectEqual(@as(u32, 1), volume.imageSubresource.layerCount);
    try std.testing.expectEqual(@as(u32, 2), volume.imageExtent.depth);
    copy.offset = std.math.maxInt(u64) - 3;
    try std.testing.expectError(error.InvalidArgument, buffer_copy_region(std.math.maxInt(u64), texture, copy));
}

test "compressed buffer copy converts block rows to Vulkan texels" {
    var texture = std.mem.zeroes(vk_resources.TextureResource);
    texture.width = 10;
    texture.height = 12;
    texture.depth_or_array_layers = 1;
    texture.mip_levels = 1;
    texture.sample_count = 1;
    texture.dimension = model_gpu_types.WGPUTextureDimension_2D;
    texture.format = model_gpu_types.WGPUTextureFormat_ASTC5x4Unorm;
    const copy = BufferCopy{ .offset = 0, .bytes_per_row = 256, .rows_per_image = 3, .mip = 0, .width = 10, .height = 12, .depth_or_layers = 1 };
    const region = try buffer_copy_region(256 * 2 + 32, texture, copy);
    try std.testing.expectEqual(@as(u32, 80), region.bufferRowLength);
    try std.testing.expectEqual(@as(u32, 12), region.bufferImageHeight);
    texture.format = model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8;
    try std.testing.expectError(error.UnsupportedFeature, buffer_copy_region(1024, texture, copy));
}

pub fn texture_write(self: anytype, cmd_arg: model_texture_types.TextureWriteCommand) !void {
    const resource = try vk_resources.ensure_texture_resource(self, cmd_arg.texture);
    if (cmd_arg.data.len == 0) {
        try vk_resources.ensure_texture_shader_layout(self, resource);
        return;
    }
    if (self.has_deferred_submissions or self.pending_uploads.items.len > 0) {
        _ = try self.flush_queue();
    }
    try vk_device.ensure_submission_state(self);
    const staging = try vk_resources.create_host_visible_buffer(self, @intCast(cmd_arg.data.len), c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    defer vk_resources.destroy_host_visible_buffer(self, staging);
    if (staging.mapped) |raw| {
        @memcpy(@as([*]u8, @ptrCast(raw))[0..cmd_arg.data.len], cmd_arg.data);
    }
    try c.check_vk(c.vkResetCommandPool(self.device, self.command_pool, 0));
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try c.check_vk(c.vkBeginCommandBuffer(self.primary_command_buffer, &begin_info));
    vk_resources.transition_texture_layout(
        self.primary_command_buffer,
        resource.*,
        resource.layout,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        0,
        c.VK_ACCESS_TRANSFER_WRITE_BIT,
        c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
    );
    var region = c.VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = if (cmd_arg.texture.bytes_per_row > 0)
            cmd_arg.texture.bytes_per_row / vk_resources.bytes_per_pixel_for_texture_format(cmd_arg.texture.format)
        else
            0,
        .bufferImageHeight = cmd_arg.texture.rows_per_image,
        .imageSubresource = .{
            .aspectMask = vk_formats.aspect_mask_for_format(cmd_arg.texture.format),
            .mipLevel = cmd_arg.texture.mip_level,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{
            .width = @max(cmd_arg.texture.width >> @intCast(cmd_arg.texture.mip_level), 1),
            .height = @max(cmd_arg.texture.height >> @intCast(cmd_arg.texture.mip_level), 1),
            .depth = 1,
        },
    };
    c.vkCmdCopyBufferToImage(self.primary_command_buffer, staging.buffer, resource.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @ptrCast(&region));
    vk_resources.transition_texture_layout(
        self.primary_command_buffer,
        resource.*,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        c.VK_IMAGE_LAYOUT_GENERAL,
        c.VK_ACCESS_TRANSFER_WRITE_BIT,
        c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    );
    try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));
    try submit_and_wait_timeline(self);
    vk_resources.mark_texture_image_layout(self, resource.image, c.VK_IMAGE_LAYOUT_GENERAL);
}

pub fn texture_read(self: anytype, args: struct {
    handle: u64,
    mip_level: u32,
    width: u32,
    height: u32,
    format: model_gpu_types.WGPUTextureFormat,
    dst_buffer: *anyopaque,
    dst_offset: u64,
    dst_bytes_per_row: u32,
    dst_rows_per_image: u32,
}) !void {
    const texture = self.textures.getPtr(args.handle) orelse return error.InvalidState;
    if (self.has_deferred_submissions or self.pending_uploads.items.len > 0) {
        _ = try self.flush_queue();
    }
    try vk_device.ensure_submission_state(self);
    const rows = if (args.dst_rows_per_image > 0) args.dst_rows_per_image else args.height;
    const bpp = vk_resources.bytes_per_pixel_for_texture_format(args.format);
    const byte_count: u64 = @as(u64, args.dst_bytes_per_row) * rows;
    const staging = try vk_resources.create_host_visible_buffer(self, byte_count, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    defer vk_resources.destroy_host_visible_buffer(self, staging);
    try c.check_vk(c.vkResetCommandPool(self.device, self.command_pool, 0));
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try c.check_vk(c.vkBeginCommandBuffer(self.primary_command_buffer, &begin_info));
    const prev_layout = texture.layout;
    vk_resources.transition_texture_layout(
        self.primary_command_buffer,
        texture.*,
        prev_layout,
        c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        vk_resources.texture_transition_source(prev_layout).src_access_mask,
        c.VK_ACCESS_TRANSFER_READ_BIT,
        vk_resources.texture_transition_source(prev_layout).src_stage,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
    );
    const copy_extent = texture_read_copy_extent(args.width, args.height);
    var region = c.VkBufferImageCopy{
        .bufferOffset = 0,
        .bufferRowLength = if (args.dst_bytes_per_row > 0) args.dst_bytes_per_row / bpp else 0,
        .bufferImageHeight = rows,
        .imageSubresource = .{
            .aspectMask = vk_formats.aspect_mask_for_format(args.format),
            .mipLevel = args.mip_level,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{
            .width = copy_extent.width,
            .height = copy_extent.height,
            .depth = 1,
        },
    };
    c.vkCmdCopyImageToBuffer(self.primary_command_buffer, texture.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging.buffer, 1, @ptrCast(&region));
    vk_resources.transition_texture_layout(
        self.primary_command_buffer,
        texture.*,
        c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        c.VK_IMAGE_LAYOUT_GENERAL,
        c.VK_ACCESS_TRANSFER_READ_BIT,
        c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    );
    try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));
    try submit_and_wait_timeline(self);
    vk_resources.mark_texture_image_layout(self, texture.image, c.VK_IMAGE_LAYOUT_GENERAL);
    if (staging.mapped) |raw| {
        const dst: [*]u8 = @ptrCast(args.dst_buffer);
        const off: usize = @intCast(args.dst_offset);
        const n: usize = @intCast(byte_count);
        @memcpy(dst[off .. off + n], @as([*]const u8, @ptrCast(raw))[0..n]);
    }
}

test "texture read copy extent is already mip-relative" {
    const extent = texture_read_copy_extent(32, 16);
    try std.testing.expectEqual(@as(u32, 32), extent.width);
    try std.testing.expectEqual(@as(u32, 16), extent.height);
}

pub fn texture_copy(self: anytype, args: struct {
    src_handle: u64,
    src_mip: u32,
    src_x: u32,
    src_y: u32,
    src_z: u32,
    dst_handle: u64,
    dst_mip: u32,
    dst_x: u32,
    dst_y: u32,
    dst_z: u32,
    width: u32,
    height: u32,
    depth_or_layers: u32,
}) !void {
    const src = self.textures.getPtr(args.src_handle) orelse return error.InvalidState;
    const dst = self.textures.getPtr(args.dst_handle) orelse return error.InvalidState;
    if (self.has_deferred_submissions or self.pending_uploads.items.len > 0) {
        _ = try self.flush_queue();
    }
    const src_prev = src.layout;
    if (src_prev == c.VK_IMAGE_LAYOUT_UNDEFINED) return error.InvalidState;
    const dst_prev = dst.layout;
    try vk_device.ensure_submission_state(self);
    try c.check_vk(c.vkResetCommandPool(self.device, self.command_pool, 0));
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try c.check_vk(c.vkBeginCommandBuffer(self.primary_command_buffer, &begin_info));
    vk_resources.transition_texture_layout(self.primary_command_buffer, src.*, src_prev, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk_resources.texture_transition_source(src_prev).src_access_mask, c.VK_ACCESS_TRANSFER_READ_BIT, vk_resources.texture_transition_source(src_prev).src_stage, c.VK_PIPELINE_STAGE_TRANSFER_BIT);
    vk_resources.transition_texture_layout(self.primary_command_buffer, dst.*, dst_prev, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk_resources.texture_transition_source(dst_prev).src_access_mask, c.VK_ACCESS_TRANSFER_WRITE_BIT, vk_resources.texture_transition_source(dst_prev).src_stage, c.VK_PIPELINE_STAGE_TRANSFER_BIT);
    const layers = if (args.depth_or_layers > 0) args.depth_or_layers else 1;
    var region = c.VkImageCopy{
        .srcSubresource = .{ .aspectMask = vk_formats.aspect_mask_for_format(src.format), .mipLevel = args.src_mip, .baseArrayLayer = 0, .layerCount = layers },
        .srcOffset = .{ .x = @intCast(args.src_x), .y = @intCast(args.src_y), .z = @intCast(args.src_z) },
        .dstSubresource = .{ .aspectMask = vk_formats.aspect_mask_for_format(dst.format), .mipLevel = args.dst_mip, .baseArrayLayer = 0, .layerCount = layers },
        .dstOffset = .{ .x = @intCast(args.dst_x), .y = @intCast(args.dst_y), .z = @intCast(args.dst_z) },
        .extent = .{ .width = args.width, .height = args.height, .depth = 1 },
    };
    c.vkCmdCopyImage(self.primary_command_buffer, src.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, dst.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, @ptrCast(&region));
    vk_resources.transition_texture_layout(self.primary_command_buffer, src.*, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_ACCESS_TRANSFER_READ_BIT, c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
    vk_resources.transition_texture_layout(self.primary_command_buffer, dst.*, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_ACCESS_TRANSFER_WRITE_BIT, c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT);
    try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));
    try submit_and_wait_timeline(self);
    vk_resources.mark_texture_image_layout(self, src.image, c.VK_IMAGE_LAYOUT_GENERAL);
    vk_resources.mark_texture_image_layout(self, dst.image, c.VK_IMAGE_LAYOUT_GENERAL);
}

pub fn texture_query(self: anytype, cmd_arg: model_texture_types.TextureQueryCommand) !void {
    const texture = self.textures.get(cmd_arg.handle) orelse return error.InvalidState;
    if (cmd_arg.expected_width) |width| if (texture.width != width) return error.InvalidState;
    if (cmd_arg.expected_height) |height| if (texture.height != height) return error.InvalidState;
    if (cmd_arg.expected_depth_or_array_layers) |layers| if (texture.depth_or_array_layers != layers) return error.InvalidState;
    if (cmd_arg.expected_format) |format| if (texture.format != format) return error.InvalidState;
    if (cmd_arg.expected_dimension) |dimension| if (texture.dimension != dimension) return error.InvalidState;
    if (cmd_arg.expected_view_dimension) |view_dimension| if (texture.view_dimension != view_dimension) return error.InvalidState;
    if (cmd_arg.expected_sample_count) |sample_count| if (texture.sample_count != sample_count) return error.InvalidState;
    if (cmd_arg.expected_usage) |usage| if ((texture.usage & usage) != usage) return error.InvalidState;
}

pub fn texture_destroy(self: anytype, cmd_arg: model_texture_types.TextureDestroyCommand) !void {
    if (self.textures.fetchRemove(cmd_arg.handle)) |entry| {
        vk_resources.release_texture_resource(self, entry.value);
    }
}

pub fn sampler_create(self: anytype, cmd: model_render_types.SamplerCreateCommand) !void {
    _ = try vk_resources.create_sampler(self, cmd);
}

pub fn sampler_destroy(self: anytype, cmd: model_render_types.SamplerDestroyCommand) !void {
    vk_resources.destroy_sampler(self, cmd.handle);
}

const vk_pipeline = @import("vk_pipeline.zig");

pub fn collect_dispatch_gpu_timestamp(self: anytype) !u64 {
    var query_pool: c.VkQueryPool = c.VK_NULL_U64;
    defer if (query_pool != c.VK_NULL_U64) c.vkDestroyQueryPool(self.device, query_pool, null);
    var create_info = c.VkQueryPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queryType = c.VK_QUERY_TYPE_TIMESTAMP,
        .queryCount = 2,
        .pipelineStatistics = 0,
    };
    try c.check_vk(c.vkCreateQueryPool(self.device, &create_info, null, &query_pool));
    try c.check_vk(c.vkResetCommandPool(self.device, self.command_pool, 0));
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try c.check_vk(c.vkBeginCommandBuffer(self.primary_command_buffer, &begin_info));
    c.vkCmdWriteTimestamp(self.primary_command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, query_pool, 0);
    c.vkCmdBindPipeline(self.primary_command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    vk_pipeline.bind_descriptor_sets(self, self.primary_command_buffer);
    c.vkCmdDispatch(self.primary_command_buffer, 1, 1, 1);
    c.vkCmdWriteTimestamp(self.primary_command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, query_pool, 1);
    try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));
    try submit_and_wait_timeline(self);
    var results: [2]u64 = .{ 0, 0 };
    try c.check_vk(c.vkGetQueryPoolResults(self.device, query_pool, 0, 2, @sizeOf(@TypeOf(results)), &results, @sizeOf(u64), c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WAIT_BIT));
    if (results[1] <= results[0]) return 0;
    return results[1] - results[0];
}

// Submit current command buffer and wait (timeline or fence).
fn submit_and_wait_timeline(self: anytype) !void {
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
    if (self.has_timeline_semaphore) {
        var tsi = vk_sync.TimelineSubmitHelper.prepare(&self.timeline_semaphore);
        tsi.patch();
        submit_info.pNext = @ptrCast(&tsi.timeline_info);
        submit_info.signalSemaphoreCount = 1;
        submit_info.pSignalSemaphores = @ptrCast(&tsi.semaphore);
        try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), c.VK_NULL_U64));
        try self.timeline_semaphore.wait(self.device, tsi.signal_value);
    } else {
        try c.check_vk(c.vkResetFences(self.device, 1, @ptrCast(&self.fence)));
        try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), self.fence));
        try c.check_vk(c.vkWaitForFences(self.device, 1, @ptrCast(&self.fence), c.VK_TRUE, vk_upload.WAIT_TIMEOUT_NS));
    }
}
