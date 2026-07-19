const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_surface_control_types = @import("../../contracts/model/model_surface_control_types.zig");
const c = @import("vk_constants.zig");
const vulkan_surface = @import("vulkan_surface.zig");

pub const SurfaceState = vulkan_surface.VulkanSurface;
pub const SurfaceConfigureCommand = model_surface_control_types.SurfaceConfigureCommand;
pub const WGPUTextureFormat = model_gpu_types.WGPUTextureFormat;

pub fn create_surface(self: anytype, handle: u64) !void {
    if (handle == 0) return error.InvalidArgument;
    const result = try self.surfaces.getOrPut(self.allocator, handle);
    if (result.found_existing) return error.InvalidState;
    result.value_ptr.* = .{};
}

pub fn get_surface_capabilities(self: anytype, handle: u64) !void {
    const surface = self.surfaces.getPtr(handle) orelse return error.SurfaceUnavailable;
    if (surface.vk_surface != 0) {
        const caps = try vulkan_surface.query_surface_capabilities(
            self.physical_device,
            self.queue_family_index,
            surface.vk_surface,
        );
        surface.cached_capabilities = caps;
        surface.capabilities_queried = true;
    }
}

pub fn preferred_canvas_format(self: anytype) model_gpu_types.WGPUTextureFormat {
    var it = self.surfaces.valueIterator();
    while (it.next()) |surface| {
        if (!surface.capabilities_queried or surface.cached_capabilities.format_count == 0) continue;
        return vulkan_surface.preferred_canvas_format_from_surface_formats(
            surface.cached_capabilities.formats[0..@as(usize, surface.cached_capabilities.format_count)],
        );
    }
    return model_gpu_types.WGPUTextureFormat_BGRA8Unorm;
}

pub fn configure_surface(self: anytype, cmd_arg: model_surface_control_types.SurfaceConfigureCommand) !void {
    if (cmd_arg.width == 0 or cmd_arg.height == 0) return error.InvalidArgument;
    const surface = self.surfaces.getPtr(cmd_arg.handle) orelse return error.SurfaceUnavailable;
    if (surface.vk_surface == 0) return error.SurfaceUnavailable;
    if (surface.configured and surface.swapchain != 0) {
        vulkan_surface.destroy_swapchain(self.device, surface);
    }
    surface.configured = true;
    surface.acquired = false;
    surface.width = cmd_arg.width;
    surface.height = cmd_arg.height;
    surface.requested_format = if (cmd_arg.format == 0) preferred_canvas_format(self) else cmd_arg.format;
    surface.format = surface.requested_format;
    surface.usage = if (cmd_arg.usage == 0) model_gpu_types.WGPUTextureUsage_RenderAttachment else cmd_arg.usage;
    surface.alpha_mode = if (cmd_arg.alpha_mode == 0) c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR else cmd_arg.alpha_mode;
    surface.present_mode = if (cmd_arg.present_mode == 0) c.VK_PRESENT_MODE_FIFO_KHR else cmd_arg.present_mode;
    surface.tone_mapping_mode = if (cmd_arg.tone_mapping_mode == 0)
        model_surface_control_types.WGPUCanvasToneMappingMode_Standard
    else
        cmd_arg.tone_mapping_mode;
    surface.desired_maximum_frame_latency = if (cmd_arg.desired_maximum_frame_latency == 0)
        c.DEFAULT_SURFACE_MAX_FRAME_LATENCY
    else
        cmd_arg.desired_maximum_frame_latency;
    try get_surface_capabilities(self, cmd_arg.handle);
    try vulkan_surface.create_swapchain(
        self.device,
        self.physical_device,
        surface,
        self.queue_family_index,
    );
}

pub fn acquire_surface(self: anytype, handle: u64) !void {
    const surface = self.surfaces.getPtr(handle) orelse return error.SurfaceUnavailable;
    if (!surface.configured or surface.acquired) return error.SurfaceUnavailable;
    if (surface.swapchain == 0) return error.SurfaceUnavailable;
    _ = try vulkan_surface.acquire_next_image(self.device, surface);
}

pub fn present_surface(self: anytype, handle: u64) !void {
    const surface = self.surfaces.getPtr(handle) orelse return error.SurfaceUnavailable;
    if (!surface.configured or !surface.acquired) return error.SurfaceUnavailable;
    if (surface.swapchain == 0) return error.SurfaceUnavailable;
    try vulkan_surface.present_image(self.queue, surface);
}

pub fn unconfigure_surface(self: anytype, handle: u64) !void {
    const surface = self.surfaces.getPtr(handle) orelse return error.SurfaceUnavailable;
    if (surface.swapchain != 0) {
        vulkan_surface.destroy_swapchain(self.device, surface);
    }
    surface.configured = false;
    surface.acquired = false;
    surface.width = 0;
    surface.height = 0;
    surface.last_acquire_suboptimal = false;
    surface.last_present_suboptimal = false;
}

pub fn release_surface(self: anytype, handle: u64) !void {
    const removed = self.surfaces.fetchRemove(handle) orelse return error.SurfaceUnavailable;
    var surface_copy = removed.value;
    if (surface_copy.vk_surface != 0 or surface_copy.swapchain != 0) {
        vulkan_surface.destroy_all(self.instance, self.device, &surface_copy);
    }
}

pub fn release_all_surfaces(self: anytype) void {
    var it = self.surfaces.valueIterator();
    while (it.next()) |surface| {
        if (surface.vk_surface != 0 or surface.swapchain != 0) {
            vulkan_surface.destroy_all(self.instance, self.device, surface);
        }
    }
    self.surfaces.deinit(self.allocator);
}
