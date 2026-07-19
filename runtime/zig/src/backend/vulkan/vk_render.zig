// Render pass creation, draw call execution, and render bundle replay.
// Pipeline creation in vk_render_pipeline.zig.
const std = @import("std");
const log = std.log.scoped(.vk_render);
const c = @import("vk_constants.zig");
const vk_device = @import("vk_device.zig");
const vk_sync = @import("vk_sync.zig");
const vk_formats = @import("vk_formats.zig");
const vk_upload = @import("vk_upload.zig");
const vk_resources = @import("vk_resources.zig");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const common_timing = @import("../common/timing.zig");
const render_bundle = @import("../../runtime/render/render_bundle.zig");
const vk_render_pipeline = @import("vk_render_pipeline.zig");
const DispatchMetrics = @import("vk_metrics.zig").DispatchMetrics;
const VK_NULL_U64 = c.VK_NULL_U64;
const VK_QUERY_CONTROL_NONE: u32 = 0;
const VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT: u32 = 0x00000020;
const VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL: u32 = 3;
const VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT: u32 = 0x00000100;
const VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT: u32 = 0x00000200;
const VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT: u32 = 0x00000200;
const VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT: u32 = 0x00000400;
const WGPU_INDEX_FORMAT_UINT16: u32 = 0x00000001;
const WGPU_INDEX_FORMAT_UINT32: u32 = 0x00000002;
const VK_PIPELINE_STAGE_GRAPHICS_SHADER_BITS: u32 = c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;

const SurfaceSubmitSync = struct {
    wait_semaphore: c.VkSemaphore = VK_NULL_U64,
    signal_semaphore: c.VkSemaphore = VK_NULL_U64,
};

pub const RenderState = struct {
    render_pass: c.VkRenderPass = VK_NULL_U64,
    framebuffer: c.VkFramebuffer = VK_NULL_U64,
    graphics_pipeline: c.VkPipeline = VK_NULL_U64,
    graphics_pipeline_layout: c.VkPipelineLayout = VK_NULL_U64,
    vertex_shader: c.VkShaderModule = VK_NULL_U64,
    fragment_shader: c.VkShaderModule = VK_NULL_U64,
    descriptor_set_layout: u64 = VK_NULL_U64,
    descriptor_pool: u64 = VK_NULL_U64,
    descriptor_set: u64 = VK_NULL_U64,
    render_target: ?vk_resources.TextureResource = null,
    depth_stencil_target: ?vk_resources.TextureResource = null,
    render_target_handle: u64 = 0,
    render_target_view_handle: u64 = 0,
    target_width: u32 = 0,
    target_height: u32 = 0,
    target_format: u32 = 0,
    owns_render_target: bool = false,
    owns_depth_stencil_target: bool = false,
};

fn destroyVkHandle(device: c.VkDevice, handle: *u64, destroy_fn: anytype) void {
    if (handle.* != VK_NULL_U64) {
        destroy_fn(device, handle.*, null);
        handle.* = VK_NULL_U64;
    }
}

pub fn release_render_state(device: c.VkDevice, state: *RenderState) void {
    destroyVkHandle(device, &state.descriptor_pool, c.vkDestroyDescriptorPool);
    state.descriptor_set = VK_NULL_U64;
    destroyVkHandle(device, &state.descriptor_set_layout, c.vkDestroyDescriptorSetLayout);
    destroyVkHandle(device, &state.graphics_pipeline, c.vkDestroyPipeline);
    destroyVkHandle(device, &state.graphics_pipeline_layout, c.vkDestroyPipelineLayout);
    destroyVkHandle(device, &state.fragment_shader, c.vkDestroyShaderModule);
    destroyVkHandle(device, &state.vertex_shader, c.vkDestroyShaderModule);
    destroyVkHandle(device, &state.framebuffer, c.vkDestroyFramebuffer);
    destroyVkHandle(device, &state.render_pass, c.vkDestroyRenderPass);
    if (state.owns_render_target) {
        if (state.render_target) |target|
            vk_resources.release_texture_resource_with_device(device, target);
    }
    state.render_target = null;
    if (state.owns_depth_stencil_target) {
        if (state.depth_stencil_target) |target|
            vk_resources.release_texture_resource_with_device(device, target);
    }
    state.depth_stencil_target = null;
}
pub fn execute_render_draw(
    self: anytype,
    cmd: model_render_types.RenderDrawCommand,
) !DispatchMetrics {
    const draw_count = if (cmd.draw_count > 0) cmd.draw_count else 1;
    const target_width = if (cmd.target_width > 0) cmd.target_width else model_render_types.DEFAULT_RENDER_TARGET_WIDTH;
    const target_height = if (cmd.target_height > 0) cmd.target_height else model_render_types.DEFAULT_RENDER_TARGET_HEIGHT;
    const vk_format = try vk_resources.texture_format_to_vk(cmd.target_format);

    if (self.has_deferred_submissions or self.pending_uploads.items.len > 0) {
        _ = try vk_upload.flush_queue(self);
    }
    try vk_device.ensure_submission_state(self);

    var render_state = RenderState{};
    defer release_render_state(self.device, &render_state);
    const encode_start = common_timing.now_ns();
    try ensure_render_target(self, &render_state, cmd, target_width, target_height, cmd.target_format, cmd.depth_stencil_format);
    const has_depth_stencil = cmd.depth_stencil_format != model_gpu_types.WGPUTextureFormat_Undefined;
    const depth_stencil_vk_format = if (has_depth_stencil) try vk_resources.texture_format_to_vk(cmd.depth_stencil_format) else 0;
    try create_render_pass(
        self,
        &render_state,
        vk_format,
        has_depth_stencil,
        depth_stencil_vk_format,
        c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    );
    try create_framebuffer(self, &render_state, target_width, target_height);
    try create_graphics_pipeline(self, &render_state, vk_format, cmd);
    const encode_end = common_timing.now_ns();
    const setup_ns = common_timing.ns_delta(encode_end, encode_start);
    const draw_start = common_timing.now_ns();
    try record_and_submit_draws(self, &render_state, cmd, draw_count, target_width, target_height);
    const draw_end = common_timing.now_ns();
    return .{
        .encode_ns = setup_ns,
        .submit_wait_ns = common_timing.ns_delta(draw_end, draw_start),
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

pub fn execute_render_clear(
    self: anytype,
    cmd: model_render_types.RenderDrawCommand,
) !DispatchMetrics {
    const target_width = if (cmd.target_width > 0) cmd.target_width else model_render_types.DEFAULT_RENDER_TARGET_WIDTH;
    const target_height = if (cmd.target_height > 0) cmd.target_height else model_render_types.DEFAULT_RENDER_TARGET_HEIGHT;
    const vk_format = try vk_resources.texture_format_to_vk(cmd.target_format);

    if (self.has_deferred_submissions or self.pending_uploads.items.len > 0) {
        _ = try vk_upload.flush_queue(self);
    }
    try vk_device.ensure_submission_state(self);

    var render_state = RenderState{};
    defer release_render_state(self.device, &render_state);

    const encode_start = common_timing.now_ns();
    try ensure_render_target(
        self,
        &render_state,
        cmd,
        target_width,
        target_height,
        cmd.target_format,
        model_gpu_types.WGPUTextureFormat_Undefined,
    );
    const surface_sync = surface_sync_for_target(self, cmd.target_handle);
    const color_final_layout = if (surface_sync.signal_semaphore != VK_NULL_U64)
        c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR
    else
        c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    try create_render_pass(
        self,
        &render_state,
        vk_format,
        false,
        0,
        color_final_layout,
    );
    try create_framebuffer(self, &render_state, target_width, target_height);
    const encode_end = common_timing.now_ns();

    const submit_start = common_timing.now_ns();
    try record_and_submit_clear(self, &render_state, cmd, target_width, target_height, surface_sync);
    const submit_end = common_timing.now_ns();
    if (render_state.render_target_handle != 0) {
        if (self.textures.getPtr(render_state.render_target_handle)) |texture| {
            texture.layout = color_final_layout;
        }
        if (render_state.render_target_view_handle != 0) {
            if (self.textures.getPtr(render_state.render_target_view_handle)) |view| {
                view.layout = color_final_layout;
            }
        }
    }
    return .{
        .encode_ns = common_timing.ns_delta(encode_end, encode_start),
        .submit_wait_ns = common_timing.ns_delta(submit_end, submit_start),
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
        .submit_count = 1,
    };
}

fn ensure_render_target(
    self: anytype,
    state: *RenderState,
    cmd: model_render_types.RenderDrawCommand,
    width: u32,
    height: u32,
    format: model_gpu_types.WGPUTextureFormat,
    depth_stencil_format: model_gpu_types.WGPUTextureFormat,
) !void {
    if (try bind_existing_render_target(self, state, cmd, width, height, format)) {
        if (depth_stencil_format != model_gpu_types.WGPUTextureFormat_Undefined) {
            const depth_texture_spec = model_resource_types.CopyTextureResource{
                .handle = 0,
                .width = width,
                .height = height,
                .format = depth_stencil_format,
                .usage = model_gpu_types.WGPUTextureUsage_RenderAttachment,
                .mip_level = 0,
                .bytes_per_row = 0,
                .rows_per_image = 0,
            };
            state.depth_stencil_target = try create_render_target_texture(self, depth_texture_spec);
            state.owns_depth_stencil_target = true;
        }
        state.target_width = width;
        state.target_height = height;
        return;
    }

    const usage = model_gpu_types.WGPUTextureUsage_RenderAttachment | model_gpu_types.WGPUTextureUsage_CopyDst;
    const texture_spec = model_resource_types.CopyTextureResource{
        .handle = 0,
        .width = width,
        .height = height,
        .format = format,
        .usage = usage,
        .mip_level = 0,
        .bytes_per_row = 0,
        .rows_per_image = 0,
    };
    state.render_target = try create_render_target_texture(self, texture_spec);
    state.owns_render_target = true;
    if (depth_stencil_format != model_gpu_types.WGPUTextureFormat_Undefined) {
        const depth_texture_spec = model_resource_types.CopyTextureResource{
            .handle = 0,
            .width = width,
            .height = height,
            .format = depth_stencil_format,
            .usage = model_gpu_types.WGPUTextureUsage_RenderAttachment,
            .mip_level = 0,
            .bytes_per_row = 0,
            .rows_per_image = 0,
        };
        state.depth_stencil_target = try create_render_target_texture(self, depth_texture_spec);
        state.owns_depth_stencil_target = true;
    }
    state.target_width = width;
    state.target_height = height;
}

fn bind_existing_render_target(
    self: anytype,
    state: *RenderState,
    cmd: model_render_types.RenderDrawCommand,
    width: u32,
    height: u32,
    format: model_gpu_types.WGPUTextureFormat,
) !bool {
    if (cmd.target_handle == 0 or cmd.target_handle == model_render_types.DEFAULT_RENDER_TARGET_HANDLE) return false;
    const texture = self.textures.get(cmd.target_handle) orelse return error.InvalidState;
    const view_resource = if (cmd.target_view_handle != 0)
        self.textures.get(cmd.target_view_handle) orelse return error.InvalidState
    else
        texture;
    state.render_target = .{
        .image = texture.image,
        .memory = texture.memory,
        .view = view_resource.view,
        .width = if (width > 0) width else texture.width,
        .height = if (height > 0) height else texture.height,
        .depth_or_array_layers = texture.depth_or_array_layers,
        .mip_levels = texture.mip_levels,
        .sample_count = texture.sample_count,
        .dimension = texture.dimension,
        .view_dimension = view_resource.view_dimension,
        .aspect = view_resource.aspect,
        .format = if (format != 0) format else texture.format,
        .usage = texture.usage,
        .layout = texture.layout,
    };
    state.render_target_handle = cmd.target_handle;
    state.render_target_view_handle = cmd.target_view_handle;
    return true;
}

fn create_render_target_texture(
    self: anytype,
    spec: model_resource_types.CopyTextureResource,
) !vk_resources.TextureResource {
    var image: c.VkImage = VK_NULL_U64;
    var memory: c.VkDeviceMemory = VK_NULL_U64;
    var view: c.VkImageView = VK_NULL_U64;
    const vk_format = try vk_resources.texture_format_to_vk(spec.format);

    const is_depth_stencil = vk_formats.is_depth_stencil(spec.format);
    var image_info = c.VkImageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = vk_format,
        .extent = .{ .width = spec.width, .height = spec.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = if (is_depth_stencil)
            VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
        else
            c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
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

    var view_info = c.VkImageViewCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = vk_format,
        .components = .{
            .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = vk_formats.aspect_mask_for_format(spec.format),
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    try c.check_vk(c.vkCreateImageView(self.device, &view_info, null, &view));
    errdefer if (view != VK_NULL_U64) c.vkDestroyImageView(self.device, view, null);

    return .{
        .image = image,
        .memory = memory,
        .view = view,
        .width = spec.width,
        .height = spec.height,
        .depth_or_array_layers = if (spec.depth_or_array_layers > 0) spec.depth_or_array_layers else 1,
        .mip_levels = 1,
        .sample_count = if (spec.sample_count > 0) spec.sample_count else 1,
        .dimension = if (spec.dimension != 0) spec.dimension else model_gpu_types.WGPUTextureDimension_2D,
        .view_dimension = if (spec.view_dimension != 0) spec.view_dimension else model_gpu_types.WGPUTextureViewDimension_2D,
        .aspect = if (spec.aspect != 0) spec.aspect else model_gpu_types.WGPUTextureAspect_All,
        .format = spec.format,
        .usage = spec.usage,
        .layout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
}

fn create_render_pass(
    self: anytype,
    state: *RenderState,
    vk_format: u32,
    has_depth_stencil: bool,
    depth_stencil_vk_format: u32,
    color_final_layout: u32,
) !void {
    const color_initial_layout = if (state.render_target) |target| target.layout else c.VK_IMAGE_LAYOUT_UNDEFINED;
    const depth_initial_layout = if (state.depth_stencil_target) |target| target.layout else c.VK_IMAGE_LAYOUT_UNDEFINED;
    var attachments = [_]c.VkAttachmentDescription{
        .{
            .flags = 0,
            .format = vk_format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = color_initial_layout,
            .finalLayout = color_final_layout,
        },
        .{
            .flags = 0,
            .format = depth_stencil_vk_format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = depth_initial_layout,
            .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        },
    };

    var color_ref = c.VkAttachmentReference{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    var depth_stencil_ref = c.VkAttachmentReference{
        .attachment = 1,
        .layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    var subpass = c.VkSubpassDescription{
        .flags = 0,
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = @ptrCast(&color_ref),
        .pResolveAttachments = null,
        .pDepthStencilAttachment = if (has_depth_stencil) @ptrCast(&depth_stencil_ref) else null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };

    var dependency = c.VkSubpassDependency{
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask = if (has_depth_stencil)
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT |
                VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
                VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT
        else
            c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = if (has_depth_stencil)
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
                VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT
        else
            c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dependencyFlags = 0,
    };

    var render_pass_info = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = if (has_depth_stencil) 2 else 1,
        .pAttachments = attachments[0..if (has_depth_stencil) 2 else 1].ptr,
        .subpassCount = 1,
        .pSubpasses = @ptrCast(&subpass),
        .dependencyCount = 1,
        .pDependencies = @ptrCast(&dependency),
    };
    try c.check_vk(c.vkCreateRenderPass(self.device, &render_pass_info, null, &state.render_pass));
}

fn create_framebuffer(
    self: anytype,
    state: *RenderState,
    width: u32,
    height: u32,
) !void {
    const target = state.render_target orelse return error.InvalidState;
    var attachments = [_]c.VkImageView{
        target.view,
        if (state.depth_stencil_target) |depth| depth.view else VK_NULL_U64,
    };

    var fb_info = c.VkFramebufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .renderPass = state.render_pass,
        .attachmentCount = if (state.depth_stencil_target != null) 2 else 1,
        .pAttachments = attachments[0..if (state.depth_stencil_target != null) 2 else 1].ptr,
        .width = width,
        .height = height,
        .layers = 1,
    };
    try c.check_vk(c.vkCreateFramebuffer(self.device, &fb_info, null, &state.framebuffer));
}

fn create_graphics_pipeline(
    self: anytype,
    state: *RenderState,
    vk_format: u32,
    cmd: model_render_types.RenderDrawCommand,
) !void {
    return vk_render_pipeline.create_graphics_pipeline(self, state, vk_format, cmd);
}

fn resolve_vk_buffer_handle(self: anytype, handle: ?*anyopaque) ?c.VkBuffer {
    const ptr = handle orelse return null;
    const cb = self.compute_buffers.get(@intFromPtr(ptr)) orelse return null;
    return cb.buffer;
}

fn surface_sync_for_target(self: anytype, target_handle: u64) SurfaceSubmitSync {
    if (target_handle == 0) return .{};
    const texture = self.textures.get(target_handle) orelse return .{};
    var it = self.surfaces.valueIterator();
    while (it.next()) |surface| {
        if (!surface.configured or !surface.acquired) continue;
        if (surface.current_image_index >= surface.swapchain_image_count) continue;
        const image_index: usize = @intCast(surface.current_image_index);
        if (surface.swapchain_images[image_index] != texture.image) continue;
        if (surface.image_available_semaphore == VK_NULL_U64 or
            surface.render_finished_semaphore == VK_NULL_U64)
        {
            return .{};
        }
        return .{
            .wait_semaphore = surface.image_available_semaphore,
            .signal_semaphore = surface.render_finished_semaphore,
        };
    }
    return .{};
}

fn mark_texture_image_layout(self: anytype, image: c.VkImage, layout: u32) void {
    var iterator = self.textures.valueIterator();
    while (iterator.next()) |texture| {
        if (texture.image == image) texture.layout = layout;
    }
}

fn transition_bound_sampled_textures(self: anytype, cmd: model_render_types.RenderDrawCommand) void {
    var ti: u32 = 0;
    while (ti < cmd.bind_texture_count and ti < model_render_types.MAX_RENDER_BIND_ENTRIES) : (ti += 1) {
        const texture = self.textures.get(cmd.bind_texture_handles[ti]) orelse continue;
        if (texture.layout == c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) continue;
        const source = vk_resources.texture_transition_source(texture.layout);
        vk_resources.transition_texture_layout(
            self.primary_command_buffer,
            texture,
            texture.layout,
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            source.src_access_mask,
            c.VK_ACCESS_SHADER_READ_BIT,
            source.src_stage,
            VK_PIPELINE_STAGE_GRAPHICS_SHADER_BITS,
        );
        mark_texture_image_layout(self, texture.image, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    }
}

fn record_and_submit_draws(
    self: anytype,
    state: *RenderState,
    cmd: model_render_types.RenderDrawCommand,
    draw_count: u32,
    target_width: u32,
    target_height: u32,
) !void {
    try begin_primary_recording(self);
    transition_bound_sampled_textures(self, cmd);

    var clear_values = [_]c.VkClearValue{
        .{
            .color = .{ .float32 = cmd.clear_color },
        },
        .{
            .depthStencil = .{ .depth = 1.0, .stencil = 0 },
        },
    };
    var render_pass_begin = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = state.render_pass,
        .framebuffer = state.framebuffer,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = target_width, .height = target_height },
        },
        .clearValueCount = if (state.depth_stencil_target != null) 2 else 1,
        .pClearValues = clear_values[0..if (state.depth_stencil_target != null) 2 else 1].ptr,
    };
    c.vkCmdBeginRenderPass(self.primary_command_buffer, &render_pass_begin, c.VK_SUBPASS_CONTENTS_INLINE);
    if (cmd.occlusion_query_pool != 0) {
        if (cmd.occlusion_query_index) |query_index| {
            const query_pool: c.VkQueryPool = @intCast(cmd.occlusion_query_pool);
            c.vkCmdResetQueryPool(self.primary_command_buffer, query_pool, query_index, 1);
            c.vkCmdBeginQuery(self.primary_command_buffer, query_pool, query_index, VK_QUERY_CONTROL_NONE);
        }
    }

    if (cmd.vertex_bindings) |bs| {
        for (bs) |binding| {
            const vk_buffer = resolve_vk_buffer_handle(self, binding.handle) orelse continue;
            const buffers_arr = [1]c.VkBuffer{vk_buffer};
            const offsets_arr = [1]u64{binding.offset};
            c.vkCmdBindVertexBuffers(self.primary_command_buffer, binding.slot, 1, &buffers_arr, &offsets_arr);
        }
    }
    const vp_width = cmd.viewport_width orelse @as(f32, @floatFromInt(target_width));
    const vp_height = cmd.viewport_height orelse @as(f32, @floatFromInt(target_height));
    var viewport = c.VkViewport{
        .x = cmd.viewport_x,
        .y = cmd.viewport_y,
        .width = vp_width,
        .height = vp_height,
        .minDepth = cmd.viewport_min_depth,
        .maxDepth = cmd.viewport_max_depth,
    };
    c.vkCmdSetViewport(self.primary_command_buffer, 0, 1, @ptrCast(&viewport));
    const sc_width = cmd.scissor_width orelse target_width;
    const sc_height = cmd.scissor_height orelse target_height;
    var scissor = c.VkRect2D{
        .offset = .{
            .x = @intCast(cmd.scissor_x),
            .y = @intCast(cmd.scissor_y),
        },
        .extent = .{ .width = sc_width, .height = sc_height },
    };
    c.vkCmdSetScissor(self.primary_command_buffer, 0, 1, @ptrCast(&scissor));

    if (cmd.depth_bias != 0 or cmd.depth_bias_slope_scale != 0 or cmd.depth_bias_clamp != 0) {
        c.vkCmdSetDepthBias(
            self.primary_command_buffer,
            @floatFromInt(cmd.depth_bias),
            cmd.depth_bias_clamp,
            cmd.depth_bias_slope_scale,
        );
    }

    if (cmd.depth_stencil_format != model_gpu_types.WGPUTextureFormat_Undefined) {
        c.vkCmdSetStencilReference(
            self.primary_command_buffer,
            c.VK_STENCIL_FACE_FRONT_AND_BACK,
            cmd.stencil_reference,
        );
    }

    // Bind graphics pipeline
    c.vkCmdBindPipeline(self.primary_command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, state.graphics_pipeline);

    if (state.descriptor_set != VK_NULL_U64) {
        const sets = [1]u64{state.descriptor_set};
        c.vkCmdBindDescriptorSets(
            self.primary_command_buffer,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            state.graphics_pipeline_layout,
            0,
            1,
            &sets,
            0,
            null,
        );
    }

    if (cmd.vertex_buffer_count > 0) {
        var vk_buffers: [8]c.VkBuffer = [_]c.VkBuffer{VK_NULL_U64} ** 8;
        var vk_offsets: [8]u64 = [_]u64{0} ** 8;
        var bound_count: u32 = 0;
        while (bound_count < cmd.vertex_buffer_count and bound_count < vk_buffers.len) : (bound_count += 1) {
            const handle = cmd.vertex_buffer_handles[bound_count];
            if (handle == 0) break;
            const compute_buffer = self.compute_buffers.get(handle) orelse return error.InvalidArgument;
            vk_buffers[bound_count] = compute_buffer.buffer;
            vk_offsets[bound_count] = cmd.vertex_buffer_offsets[bound_count];
        }
        if (bound_count > 0) {
            c.vkCmdBindVertexBuffers(
                self.primary_command_buffer,
                0,
                bound_count,
                vk_buffers[0..bound_count].ptr,
                vk_offsets[0..bound_count].ptr,
            );
        }
    }

    const vertex_count = cmd.vertex_count;
    const instance_count = cmd.instance_count;
    const first_vertex = cmd.first_vertex;
    const first_instance = cmd.first_instance;
    if (cmd.indirect_buffer_handle != 0) {
        const indirect_vk_buf = blk: {
            const cb = self.compute_buffers.get(cmd.indirect_buffer_handle) orelse return error.InvalidArgument;
            break :blk cb.buffer;
        };
        if (cmd.index_data != null or cmd.index_binding != null or cmd.index_count != null) {
            if (cmd.index_binding) |ib| {
                const vk_buf = resolve_vk_buffer_handle(self, ib.handle) orelse return error.InvalidArgument;
                const vk_index_type = if (ib.format == WGPU_INDEX_FORMAT_UINT16) c.VK_INDEX_TYPE_UINT16 else c.VK_INDEX_TYPE_UINT32;
                c.vkCmdBindIndexBuffer(self.primary_command_buffer, vk_buf, ib.offset, vk_index_type);
            } else if (cmd.index_buffer_handle != 0) {
                const vk_buf = blk2: {
                    const cb2 = self.compute_buffers.get(cmd.index_buffer_handle) orelse return error.InvalidArgument;
                    break :blk2 cb2.buffer;
                };
                const vk_index_type = if (cmd.index_format == WGPU_INDEX_FORMAT_UINT16) c.VK_INDEX_TYPE_UINT16 else c.VK_INDEX_TYPE_UINT32;
                c.vkCmdBindIndexBuffer(self.primary_command_buffer, vk_buf, cmd.index_buffer_offset, vk_index_type);
            }
            c.vkCmdDrawIndexedIndirect(self.primary_command_buffer, indirect_vk_buf, cmd.indirect_offset, 1, c.VK_DRAW_INDEXED_INDIRECT_COMMAND_STRIDE);
        } else {
            c.vkCmdDrawIndirect(self.primary_command_buffer, indirect_vk_buf, cmd.indirect_offset, 1, c.VK_DRAW_INDIRECT_COMMAND_STRIDE);
        }
    } else if (cmd.index_data != null or cmd.index_binding != null or cmd.index_count != null) {
        try record_indexed_draws(self, cmd, draw_count);
    } else {
        var draw_index: u32 = 0;
        while (draw_index < draw_count) : (draw_index += 1) {
            c.vkCmdDraw(
                self.primary_command_buffer,
                vertex_count,
                instance_count,
                first_vertex,
                first_instance,
            );
        }
    }
    if (cmd.occlusion_query_pool != 0) {
        if (cmd.occlusion_query_index) |query_index| {
            const query_pool: c.VkQueryPool = @intCast(cmd.occlusion_query_pool);
            c.vkCmdEndQuery(self.primary_command_buffer, query_pool, query_index);
        }
    }

    c.vkCmdEndRenderPass(self.primary_command_buffer);
    try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));
    try submit_and_wait(self);
    if (state.render_target_handle != 0) {
        if (self.textures.getPtr(state.render_target_handle)) |texture| {
            texture.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        }
        if (state.render_target_view_handle != 0) {
            if (self.textures.getPtr(state.render_target_view_handle)) |view| {
                view.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            }
        }
    }
}

fn begin_primary_recording(self: anytype) !void {
    try c.check_vk(c.vkResetCommandPool(self.device, self.command_pool, 0));
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try c.check_vk(c.vkBeginCommandBuffer(self.primary_command_buffer, &begin_info));
}

fn record_and_submit_clear(
    self: anytype,
    state: *RenderState,
    cmd: model_render_types.RenderDrawCommand,
    target_width: u32,
    target_height: u32,
    surface_sync: SurfaceSubmitSync,
) !void {
    try begin_primary_recording(self);

    var clear_value = c.VkClearValue{
        .color = .{ .float32 = cmd.clear_color },
    };
    var render_pass_begin = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = state.render_pass,
        .framebuffer = state.framebuffer,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = target_width, .height = target_height },
        },
        .clearValueCount = 1,
        .pClearValues = @ptrCast(&clear_value),
    };
    c.vkCmdBeginRenderPass(self.primary_command_buffer, &render_pass_begin, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdEndRenderPass(self.primary_command_buffer);
    try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));
    try submit_clear_and_wait(self, surface_sync);
}

fn submit_clear_and_wait(self: anytype, surface_sync: SurfaceSubmitSync) !void {
    if (surface_sync.wait_semaphore == VK_NULL_U64 and surface_sync.signal_semaphore == VK_NULL_U64) {
        return submit_and_wait(self);
    }

    var wait_stage = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    var wait_semaphore = surface_sync.wait_semaphore;
    var signal_semaphore = surface_sync.signal_semaphore;
    var submit_info = c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = if (wait_semaphore != VK_NULL_U64) 1 else 0,
        .pWaitSemaphores = if (wait_semaphore != VK_NULL_U64) @ptrCast(&wait_semaphore) else null,
        .pWaitDstStageMask = if (wait_semaphore != VK_NULL_U64) @ptrCast(&wait_stage) else null,
        .commandBufferCount = 1,
        .pCommandBuffers = @ptrCast(&self.primary_command_buffer),
        .signalSemaphoreCount = if (signal_semaphore != VK_NULL_U64) 1 else 0,
        .pSignalSemaphores = if (signal_semaphore != VK_NULL_U64) @ptrCast(&signal_semaphore) else null,
    };
    try c.check_vk(c.vkResetFences(self.device, 1, @ptrCast(&self.fence)));
    try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), self.fence));
    try c.check_vk(c.vkWaitForFences(self.device, 1, @ptrCast(&self.fence), c.VK_TRUE, vk_upload.WAIT_TIMEOUT_NS));
}

fn submit_and_wait(self: anytype) !void {
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
        try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), VK_NULL_U64));
        try self.timeline_semaphore.wait(self.device, tsi.signal_value);
    } else {
        try c.check_vk(c.vkResetFences(self.device, 1, @ptrCast(&self.fence)));
        try c.check_vk(c.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), self.fence));
        try c.check_vk(c.vkWaitForFences(self.device, 1, @ptrCast(&self.fence), c.VK_TRUE, vk_upload.WAIT_TIMEOUT_NS));
    }
}

fn record_indexed_draws(
    self: anytype,
    cmd: model_render_types.RenderDrawCommand,
    draw_count: u32,
) !void {
    if (cmd.index_binding) |ib| {
        const vk_buf = resolve_vk_buffer_handle(self, ib.handle) orelse return error.InvalidArgument;
        const vk_index_type = if (ib.format == WGPU_INDEX_FORMAT_UINT16) c.VK_INDEX_TYPE_UINT16 else c.VK_INDEX_TYPE_UINT32;
        c.vkCmdBindIndexBuffer(self.primary_command_buffer, vk_buf, ib.offset, vk_index_type);
        var draw_index: u32 = 0;
        while (draw_index < draw_count) : (draw_index += 1) {
            c.vkCmdDrawIndexed(
                self.primary_command_buffer,
                cmd.index_count orelse return error.InvalidArgument,
                cmd.instance_count,
                cmd.first_index,
                cmd.base_vertex,
                cmd.first_instance,
            );
        }
        return;
    }

    const index_data = cmd.index_data orelse return error.InvalidArgument;
    const index_count = cmd.index_count orelse switch (index_data) {
        .uint16 => |data| @as(u32, @intCast(data.len)),
        .uint32 => |data| @as(u32, @intCast(data.len)),
    };

    // Create index buffer with appropriate data
    const index_buffer_size: u64 = switch (index_data) {
        .uint16 => |data| @as(u64, data.len) * @sizeOf(u16),
        .uint32 => |data| @as(u64, data.len) * @sizeOf(u32),
    };
    const index_buffer = try vk_resources.create_host_visible_buffer(
        self,
        index_buffer_size,
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
    );
    defer vk_resources.destroy_host_visible_buffer(self, index_buffer);

    // Copy index data
    if (index_buffer.mapped) |raw| {
        const dst = @as([*]u8, @ptrCast(raw));
        switch (index_data) {
            .uint16 => |data| @memcpy(dst[0..@intCast(index_buffer_size)], std.mem.sliceAsBytes(data)),
            .uint32 => |data| @memcpy(dst[0..@intCast(index_buffer_size)], std.mem.sliceAsBytes(data)),
        }
    }

    const vk_index_type: u32 = switch (index_data) {
        .uint16 => c.VK_INDEX_TYPE_UINT16,
        .uint32 => c.VK_INDEX_TYPE_UINT32,
    };
    c.vkCmdBindIndexBuffer(self.primary_command_buffer, index_buffer.buffer, 0, vk_index_type);

    var draw_index: u32 = 0;
    while (draw_index < draw_count) : (draw_index += 1) {
        c.vkCmdDrawIndexed(
            self.primary_command_buffer,
            index_count,
            cmd.instance_count,
            cmd.first_index,
            cmd.base_vertex,
            cmd.first_instance,
        );
    }
}

// Replay render bundles into a standalone render pass. Creates render target,
// render pass + framebuffer, then replays each bundle's command list.
pub fn execute_render_bundles(
    self: anytype,
    bundles: []const *const render_bundle.DoeRenderBundle,
    target_width: u32,
    target_height: u32,
    color_format: u32,
    sample_count: u32,
) !DispatchMetrics {
    if (bundles.len == 0) return .{};
    if (self.has_deferred_submissions or self.pending_uploads.items.len > 0)
        _ = try vk_upload.flush_queue(self);
    try vk_device.ensure_submission_state(self);
    const width = if (target_width > 0) target_width else model_render_types.DEFAULT_RENDER_TARGET_WIDTH;
    const height = if (target_height > 0) target_height else model_render_types.DEFAULT_RENDER_TARGET_HEIGHT;
    const vk_format = try vk_resources.texture_format_to_vk(color_format);
    const pass_sample_count = if (sample_count == 0) @as(u32, 1) else sample_count;
    var state = RenderState{};
    defer release_render_state(self.device, &state);
    const encode_start = common_timing.now_ns();
    const bundle_cmd = model_render_types.RenderDrawCommand{
        .target_width = width,
        .target_height = height,
        .target_format = @intCast(color_format),
    };
    try ensure_render_target(self, &state, bundle_cmd, width, height, @intCast(color_format), model_gpu_types.WGPUTextureFormat_Undefined);
    try create_render_pass(
        self,
        &state,
        vk_format,
        false,
        0,
        c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    );
    try create_framebuffer(self, &state, width, height);
    const encode_end = common_timing.now_ns();
    const draw_start = common_timing.now_ns();
    try begin_primary_recording(self);

    var clear_value = c.VkClearValue{
        .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } },
    };
    var render_pass_begin = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = state.render_pass,
        .framebuffer = state.framebuffer,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = width, .height = height },
        },
        .clearValueCount = 1,
        .pClearValues = @ptrCast(&clear_value),
    };
    c.vkCmdBeginRenderPass(self.primary_command_buffer, &render_pass_begin, c.VK_SUBPASS_CONTENTS_INLINE);
    var viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(self.primary_command_buffer, 0, 1, @ptrCast(&viewport));
    var scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
    c.vkCmdSetScissor(self.primary_command_buffer, 0, 1, @ptrCast(&scissor));
    for (bundles) |b| {
        render_bundle.replay_bundle_vk(b, self.primary_command_buffer, color_format, pass_sample_count) catch |err| {
            log.warn("bundle replay failed: {}", .{err});
            continue;
        };
    }
    c.vkCmdEndRenderPass(self.primary_command_buffer);
    try c.check_vk(c.vkEndCommandBuffer(self.primary_command_buffer));
    try submit_and_wait(self);
    const draw_end = common_timing.now_ns();
    return .{ .encode_ns = common_timing.ns_delta(encode_end, encode_start), .submit_wait_ns = common_timing.ns_delta(draw_end, draw_start) };
}
