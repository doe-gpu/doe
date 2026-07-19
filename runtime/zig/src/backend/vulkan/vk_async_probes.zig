// Strict-mode async diagnostic probes for the Vulkan backend.
//
// resource_table_immediates: creates buffers and textures via native Vulkan,
// populates them with staging copies, and measures resource creation throughput.
//
// pixel_local_storage: creates a two-subpass render pass with a self-dependency
// for framebuffer-fetch / input-attachment emulation, and measures the render
// pass + subpass dependency barrier overhead.

const std = @import("std");
const c = @import("vk_constants.zig");
const vk_device = @import("vk_device.zig");
const vk_resources = @import("vk_resources.zig");
const vk_formats = @import("vk_formats.zig");
const vk_upload = @import("vk_upload.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const common_timing = @import("../common/timing.zig");

const VK_NULL_U64 = c.VK_NULL_U64;

// --- Named constants ---

const RTI_BUFFER_BYTES: u64 = 256;
const RTI_TEXTURE_WIDTH: u32 = 16;
const RTI_TEXTURE_HEIGHT: u32 = 16;
const RTI_TEXTURE_FORMAT: model_gpu_types.WGPUTextureFormat = model_gpu_types.WGPUTextureFormat_RGBA8Unorm;
const RTI_TEXTURE_BPP: u64 = 4;
const RTI_TEXTURE_DATA_BYTES: u64 = @as(u64, RTI_TEXTURE_WIDTH) * RTI_TEXTURE_HEIGHT * RTI_TEXTURE_BPP;

const PLS_ATTACHMENT_WIDTH: u32 = 64;
const PLS_ATTACHMENT_HEIGHT: u32 = 64;
const PLS_COLOR_FORMAT: model_gpu_types.WGPUTextureFormat = model_gpu_types.WGPUTextureFormat_RGBA8Unorm;

pub const AsyncProbeResult = struct {
    setup_ns: u64 = 0,
    encode_ns: u64 = 0,
    submit_wait_ns: u64 = 0,
};

/// Strict resource_table_immediates: create buffer + texture, populate via
/// staging copy, submit, wait, then destroy. Measures real Vulkan resource
/// creation throughput across buffer and texture paths per iteration.
pub fn resource_table_immediates_probe(
    self: anytype,
    iterations: u32,
) !AsyncProbeResult {
    const count = if (iterations > 0) iterations else 1;
    var setup_ns: u64 = 0;
    var encode_ns: u64 = 0;
    var submit_wait_ns: u64 = 0;

    var iter: u32 = 0;
    while (iter < count) : (iter += 1) {
        // --- Setup phase: create resources ---
        const setup_start = common_timing.now_ns();

        const buffer = try vk_resources.create_host_visible_buffer(
            self,
            RTI_BUFFER_BYTES,
            c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        );
        defer vk_resources.destroy_host_visible_buffer(self, buffer);

        if (buffer.mapped) |raw| {
            @memset(@as([*]u8, @ptrCast(raw))[0..@intCast(RTI_BUFFER_BYTES)], 0xAB);
        }

        const texture = try vk_resources.create_texture_resource_full(
            self,
            RTI_TEXTURE_WIDTH,
            RTI_TEXTURE_HEIGHT,
            1,
            1,
            1,
            model_gpu_types.WGPUTextureDimension_2D,
            model_gpu_types.WGPUTextureViewDimension_Undefined,
            model_gpu_types.WGPUTextureAspect_Undefined,
            RTI_TEXTURE_FORMAT,
            model_gpu_types.WGPUTextureUsage_CopyDst | model_gpu_types.WGPUTextureUsage_TextureBinding,
        );
        defer vk_resources.release_texture_resource(self, texture);

        const staging = try vk_resources.create_host_visible_buffer(
            self,
            RTI_TEXTURE_DATA_BYTES,
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        );
        defer vk_resources.destroy_host_visible_buffer(self, staging);

        if (staging.mapped) |raw| {
            @memset(@as([*]u8, @ptrCast(raw))[0..@intCast(RTI_TEXTURE_DATA_BYTES)], 0xCD);
        }

        setup_ns +|= common_timing.ns_delta(common_timing.now_ns(), setup_start);

        // --- Encode phase: record staging copy into texture ---
        const encode_start = common_timing.now_ns();

        if (self.has_deferred_submissions) _ = try vk_upload.flush_queue(self);
        try c.check_vk(c.vkResetCommandPool(self.device, self.command_pool, 0));

        var begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try c.check_vk(c.vkBeginCommandBuffer(self.primary_command_buffer, &begin_info));

        // Transition texture to transfer-dst layout
        vk_resources.transition_texture_layout(
            self.primary_command_buffer,
            texture,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            0,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        );

        var region = c.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = RTI_TEXTURE_WIDTH,
            .bufferImageHeight = RTI_TEXTURE_HEIGHT,
            .imageSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
            .imageExtent = .{ .width = RTI_TEXTURE_WIDTH, .height = RTI_TEXTURE_HEIGHT, .depth = 1 },
        };
        c.vkCmdCopyBufferToImage(
            self.primary_command_buffer,
            staging.buffer,
            texture.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            @ptrCast(&region),
        );

        // Transition texture to shader-read layout
        vk_resources.transition_texture_layout(
            self.primary_command_buffer,
            texture,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            c.VK_IMAGE_LAYOUT_GENERAL,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_ACCESS_SHADER_READ_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        );

        try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));
        encode_ns +|= common_timing.ns_delta(common_timing.now_ns(), encode_start);

        // --- Submit+wait phase ---
        const submit_start = common_timing.now_ns();
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
        submit_wait_ns +|= common_timing.ns_delta(common_timing.now_ns(), submit_start);
    }

    return .{
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns,
    };
}

/// Strict pixel_local_storage: create a two-subpass render pass with a
/// self-dependency (subpass 0 writes color, subpass 1 reads it back as an
/// input attachment). This exercises the framebuffer-fetch barrier path
/// that real pixel-local-storage workloads rely on in Vulkan.
pub fn pixel_local_storage_probe(
    self: anytype,
    iterations: u32,
    target_format: model_gpu_types.WGPUTextureFormat,
) !AsyncProbeResult {
    const count = if (iterations > 0) iterations else 1;
    const format = if (target_format != model_gpu_types.WGPUTextureFormat_Undefined) target_format else PLS_COLOR_FORMAT;
    var setup_ns: u64 = 0;
    var encode_ns: u64 = 0;
    var submit_wait_ns: u64 = 0;

    var iter: u32 = 0;
    while (iter < count) : (iter += 1) {
        // --- Setup phase: create render target and render pass ---
        const setup_start = common_timing.now_ns();

        const color_attachment = try vk_resources.create_texture_resource_full(
            self,
            PLS_ATTACHMENT_WIDTH,
            PLS_ATTACHMENT_HEIGHT,
            1,
            1,
            1,
            model_gpu_types.WGPUTextureDimension_2D,
            model_gpu_types.WGPUTextureViewDimension_Undefined,
            model_gpu_types.WGPUTextureAspect_Undefined,
            format,
            model_gpu_types.WGPUTextureUsage_RenderAttachment | model_gpu_types.WGPUTextureUsage_TextureBinding,
        );
        defer vk_resources.release_texture_resource(self, color_attachment);

        const vk_format = vk_resources.texture_format_to_vk(format) catch c.VK_FORMAT_R8G8B8A8_UNORM;

        // Two-subpass render pass: subpass 0 writes color, subpass 1 reads
        // color as input attachment (framebuffer-fetch pattern).
        var attachments = [1]c.VkAttachmentDescription{
            .{
                .flags = 0,
                .format = vk_format,
                .samples = c.VK_SAMPLE_COUNT_1_BIT,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            },
        };

        // Subpass 0: write to color attachment
        var color_ref_write = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass_0 = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = @ptrCast(&color_ref_write),
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        // Subpass 1: read color as input attachment, write to same color
        var input_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };

        var color_ref_read_write = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass_1 = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 1,
            .pInputAttachments = @ptrCast(&input_ref),
            .colorAttachmentCount = 1,
            .pColorAttachments = @ptrCast(&color_ref_read_write),
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        var subpasses = [2]c.VkSubpassDescription{ subpass_0, subpass_1 };

        // External -> subpass 0 dependency
        const dep_external_to_0 = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
        };

        // Subpass 0 -> subpass 1 self-dependency (framebuffer-fetch barrier)
        const dep_0_to_1 = c.VkSubpassDependency{
            .srcSubpass = 0,
            .dstSubpass = 1,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_INPUT_ATTACHMENT_READ_BIT,
            .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
        };

        var dependencies = [2]c.VkSubpassDependency{ dep_external_to_0, dep_0_to_1 };

        var render_pass_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &attachments,
            .subpassCount = 2,
            .pSubpasses = &subpasses,
            .dependencyCount = 2,
            .pDependencies = &dependencies,
        };

        var render_pass: c.VkRenderPass = VK_NULL_U64;
        try c.check_vk(c.vkCreateRenderPass(self.device, &render_pass_info, null, &render_pass));
        defer if (render_pass != VK_NULL_U64) c.vkDestroyRenderPass(self.device, render_pass, null);

        // Create framebuffer
        var attachment_views = [1]c.VkImageView{color_attachment.view};
        var fb_info = c.VkFramebufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = render_pass,
            .attachmentCount = 1,
            .pAttachments = &attachment_views,
            .width = PLS_ATTACHMENT_WIDTH,
            .height = PLS_ATTACHMENT_HEIGHT,
            .layers = 1,
        };
        var framebuffer: c.VkFramebuffer = VK_NULL_U64;
        try c.check_vk(c.vkCreateFramebuffer(self.device, &fb_info, null, &framebuffer));
        defer if (framebuffer != VK_NULL_U64) c.vkDestroyFramebuffer(self.device, framebuffer, null);

        setup_ns +|= common_timing.ns_delta(common_timing.now_ns(), setup_start);

        // --- Encode phase: record render pass with subpass advance ---
        const encode_start = common_timing.now_ns();

        if (self.has_deferred_submissions) _ = try vk_upload.flush_queue(self);
        try c.check_vk(c.vkResetCommandPool(self.device, self.command_pool, 0));

        var begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        try c.check_vk(c.vkBeginCommandBuffer(self.primary_command_buffer, &begin_info));

        var clear_value = c.VkClearValue{
            .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } },
        };

        var rp_begin = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = render_pass,
            .framebuffer = framebuffer,
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = .{ .width = PLS_ATTACHMENT_WIDTH, .height = PLS_ATTACHMENT_HEIGHT },
            },
            .clearValueCount = 1,
            .pClearValues = @ptrCast(&clear_value),
        };

        // Begin render pass (subpass 0)
        c.vkCmdBeginRenderPass(self.primary_command_buffer, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);

        // Advance to subpass 1 (exercises the framebuffer-fetch barrier)
        c.vkCmdNextSubpass(self.primary_command_buffer, c.VK_SUBPASS_CONTENTS_INLINE);

        // End render pass
        c.vkCmdEndRenderPass(self.primary_command_buffer);

        try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));
        encode_ns +|= common_timing.ns_delta(common_timing.now_ns(), encode_start);

        // --- Submit+wait phase ---
        const submit_start = common_timing.now_ns();
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
        submit_wait_ns +|= common_timing.ns_delta(common_timing.now_ns(), submit_start);
    }

    return .{
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns,
    };
}
