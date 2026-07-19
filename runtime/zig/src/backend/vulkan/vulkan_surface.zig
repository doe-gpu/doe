// Vulkan surface/swapchain lifecycle for Linux (Wayland/X11/headless).
//
// Platform detection is compile-time: Wayland and XCB surface extensions
// are enabled only on Linux. Headless fallback is always available.
// Swapchain images are backed by real VkImageKHR handles when a windowed
// surface is present.

const std = @import("std");
const builtin = @import("builtin");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const common_errors = @import("../common/errors.zig");
const common_timing = @import("../common/timing.zig");
const vk = @import("vulkan_types.zig");
const vulkan_errors = @import("vulkan_errors.zig");
const VkResult = vk.VkResult;
const VkBool32 = vk.VkBool32;
const VkFlags = vk.VkFlags;
const VkInstance = vk.VkInstance;
const VkPhysicalDevice = vk.VkPhysicalDevice;
const VkDevice = vk.VkDevice;
const VkQueue = vk.VkQueue;
const VkAllocationCallbacks = vk.VkAllocationCallbacks;
const VkSurfaceKHR = vk.VkSurfaceKHR;
const VkSwapchainKHR = vk.VkSwapchainKHR;
const VkImage = vk.VkImage;
const VkSemaphore = vk.VkSemaphore;
const VkFence = vk.VkFence;
const VkStructureType = vk.VkStructureType;
const VK_SUCCESS = vk.VK_SUCCESS;
const VK_SUBOPTIMAL_KHR: i32 = 1000001003;
const VK_ERROR_OUT_OF_DATE_KHR = vulkan_errors.VK_ERROR_OUT_OF_DATE_KHR;
const VK_NULL_U64 = vk.VK_NULL_U64;
const VK_TRUE = vk.VK_TRUE;
const VK_FALSE = vk.VK_FALSE;
// VkStructureType values for surface/swapchain extensions
const VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR: i32 = 1000001000;
const VK_STRUCTURE_TYPE_PRESENT_INFO_KHR: i32 = 1000001001;
const VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR: i32 = 1000006000;
const VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR: i32 = 1000005000;
const VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR: i32 = 1000004000;
const VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO: i32 = 9;
// VkFormat for swapchain
const VK_FORMAT_B8G8R8A8_SRGB: u32 = 50;
const VK_FORMAT_B8G8R8A8_UNORM: u32 = 44;
const VK_FORMAT_R8G8B8A8_UNORM: u32 = 37;
const VK_FORMAT_R16G16B16A16_SFLOAT: u32 = 97;
// VkColorSpaceKHR
const VK_COLOR_SPACE_SRGB_NONLINEAR_KHR: u32 = 0;
const VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT: u32 = 1000104002;
// VkPresentModeKHR
const VK_PRESENT_MODE_FIFO_KHR: u32 = 2;
const VK_PRESENT_MODE_MAILBOX_KHR: u32 = 3;
const VK_PRESENT_MODE_IMMEDIATE_KHR: u32 = 0;
// VkCompositeAlphaFlagBitsKHR
const VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR: u32 = 0x00000001;
const VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR: u32 = 0x00000002;
const VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR: u32 = 0x00000004;
const VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR: u32 = 0x00000008;
// VkImageUsageFlagBitsKHR
const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: u32 = 0x00000010;
const VK_IMAGE_USAGE_SAMPLED_BIT: u32 = 0x00000004;
const VK_IMAGE_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
const VK_IMAGE_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;
// VkSharingMode
const VK_SHARING_MODE_EXCLUSIVE: u32 = 0;
// Limits
const DEFAULT_SURFACE_MAX_FRAME_LATENCY: u32 = 2;
const MAX_SWAPCHAIN_IMAGES: usize = 8;
const MAX_SURFACE_FORMATS: usize = 32;
const MAX_PRESENT_MODES: usize = 8;
const ACQUIRE_TIMEOUT_NS: u64 = std.math.maxInt(u64);
// Present mode mapping from WebGPU to Vulkan
const WGPU_PRESENT_MODE_FIFO: u32 = 0x00000002;
const WGPU_PRESENT_MODE_MAILBOX: u32 = 0x00000003;
const WGPU_PRESENT_MODE_IMMEDIATE: u32 = 0x00000004;
const VkSurfaceCapabilitiesKHR = extern struct {
    minImageCount: u32,
    maxImageCount: u32,
    currentExtent: VkExtent2D,
    minImageExtent: VkExtent2D,
    maxImageExtent: VkExtent2D,
    maxImageArrayLayers: u32,
    supportedTransforms: VkFlags,
    currentTransform: VkFlags,
    supportedCompositeAlpha: VkFlags,
    supportedUsageFlags: VkFlags,
};
const VkSurfaceFormatKHR = extern struct {
    format: u32,
    colorSpace: u32,
};
const VkExtent2D = extern struct {
    width: u32,
    height: u32,
};
const VkSwapchainCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkFlags,
    surface: VkSurfaceKHR,
    minImageCount: u32,
    imageFormat: u32,
    imageColorSpace: u32,
    imageExtent: VkExtent2D,
    imageArrayLayers: u32,
    imageUsage: VkFlags,
    imageSharingMode: u32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
    preTransform: VkFlags,
    compositeAlpha: VkFlags,
    presentMode: u32,
    clipped: VkBool32,
    oldSwapchain: VkSwapchainKHR,
};
const VkPresentInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?[*]const VkSemaphore,
    swapchainCount: u32,
    pSwapchains: [*]const VkSwapchainKHR,
    pImageIndices: [*]const u32,
    pResults: ?[*]VkResult,
};
const VkSemaphoreCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkFlags,
};
const VkWaylandSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkFlags,
    display: ?*anyopaque,
    surface: ?*anyopaque,
};
const VkXcbSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkFlags,
    connection: ?*anyopaque,
    window: u32,
};
const VkXlibSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkFlags,
    dpy: ?*anyopaque,
    window: u64,
};
// Vulkan KHR extension function externs (loaded from libvulkan at link time)
extern fn vkDestroySurfaceKHR(instance: VkInstance, surface: VkSurfaceKHR, pAllocator: ?*const VkAllocationCallbacks) callconv(.c) void;
extern fn vkGetPhysicalDeviceSurfaceSupportKHR(physicalDevice: VkPhysicalDevice, queueFamilyIndex: u32, surface: VkSurfaceKHR, pSupported: *VkBool32) callconv(.c) VkResult;
extern fn vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pSurfaceCapabilities: *VkSurfaceCapabilitiesKHR) callconv(.c) VkResult;
extern fn vkGetPhysicalDeviceSurfaceFormatsKHR(physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pSurfaceFormatCount: *u32, pSurfaceFormats: ?[*]VkSurfaceFormatKHR) callconv(.c) VkResult;
extern fn vkGetPhysicalDeviceSurfacePresentModesKHR(physicalDevice: VkPhysicalDevice, surface: VkSurfaceKHR, pPresentModeCount: *u32, pPresentModes: ?[*]u32) callconv(.c) VkResult;
extern fn vkCreateSwapchainKHR(device: VkDevice, pCreateInfo: *const VkSwapchainCreateInfoKHR, pAllocator: ?*const VkAllocationCallbacks, pSwapchain: *VkSwapchainKHR) callconv(.c) VkResult;
extern fn vkDestroySwapchainKHR(device: VkDevice, swapchain: VkSwapchainKHR, pAllocator: ?*const VkAllocationCallbacks) callconv(.c) void;
extern fn vkGetSwapchainImagesKHR(device: VkDevice, swapchain: VkSwapchainKHR, pSwapchainImageCount: *u32, pSwapchainImages: ?[*]VkImage) callconv(.c) VkResult;
extern fn vkAcquireNextImageKHR(device: VkDevice, swapchain: VkSwapchainKHR, timeout: u64, semaphore: VkSemaphore, fence: VkFence, pImageIndex: *u32) callconv(.c) VkResult;
extern fn vkQueuePresentKHR(queue: VkQueue, pPresentInfo: *const VkPresentInfoKHR) callconv(.c) VkResult;
extern fn vkCreateSemaphore(device: VkDevice, pCreateInfo: *const VkSemaphoreCreateInfo, pAllocator: ?*const VkAllocationCallbacks, pSemaphore: *VkSemaphore) callconv(.c) VkResult;
extern fn vkDestroySemaphore(device: VkDevice, semaphore: VkSemaphore, pAllocator: ?*const VkAllocationCallbacks) callconv(.c) void;
extern fn vkQueueWaitIdle(queue: VkQueue) callconv(.c) VkResult;
// Platform-conditional surface creation externs (Wayland/XCB only on linux)
const is_linux = builtin.os.tag == .linux;

extern fn vkCreateWaylandSurfaceKHR(instance: VkInstance, pCreateInfo: *const VkWaylandSurfaceCreateInfoKHR, pAllocator: ?*const VkAllocationCallbacks, pSurface: *VkSurfaceKHR) callconv(.c) VkResult;
extern fn vkCreateXcbSurfaceKHR(instance: VkInstance, pCreateInfo: *const VkXcbSurfaceCreateInfoKHR, pAllocator: ?*const VkAllocationCallbacks, pSurface: *VkSurfaceKHR) callconv(.c) VkResult;
extern fn vkCreateXlibSurfaceKHR(instance: VkInstance, pCreateInfo: *const VkXlibSurfaceCreateInfoKHR, pAllocator: ?*const VkAllocationCallbacks, pSurface: *VkSurfaceKHR) callconv(.c) VkResult;
pub const SurfacePlatform = enum {
    headless,
    wayland,
    xcb,
    xlib,
};
pub const SurfaceCapabilities = struct {
    min_image_count: u32 = 0,
    max_image_count: u32 = 0,
    current_width: u32 = 0,
    current_height: u32 = 0,
    min_width: u32 = 0,
    min_height: u32 = 0,
    max_width: u32 = 0,
    max_height: u32 = 0,
    supported_usage: VkFlags = 0,
    format_count: u32 = 0,
    formats: [MAX_SURFACE_FORMATS]VkSurfaceFormatKHR = std.mem.zeroes([MAX_SURFACE_FORMATS]VkSurfaceFormatKHR),
    present_mode_count: u32 = 0,
    present_modes: [MAX_PRESENT_MODES]u32 = std.mem.zeroes([MAX_PRESENT_MODES]u32),
    present_supported: bool = false,
};
pub const VulkanSurface = struct {
    // Vulkan surface object
    vk_surface: VkSurfaceKHR = VK_NULL_U64,
    platform: SurfacePlatform = .headless,
    // Swapchain state
    swapchain: VkSwapchainKHR = VK_NULL_U64,
    swapchain_images: [MAX_SWAPCHAIN_IMAGES]VkImage = [_]VkImage{VK_NULL_U64} ** MAX_SWAPCHAIN_IMAGES,
    swapchain_image_count: u32 = 0,
    swapchain_format: u32 = VK_FORMAT_B8G8R8A8_SRGB,
    swapchain_extent: VkExtent2D = .{ .width = 0, .height = 0 },
    // Synchronization
    image_available_semaphore: VkSemaphore = VK_NULL_U64,
    render_finished_semaphore: VkSemaphore = VK_NULL_U64,
    // Configuration state (mirrors WebGPU surface semantics)
    configured: bool = false,
    acquired: bool = false,
    current_image_index: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    requested_format: model_gpu_types.WGPUTextureFormat = model_gpu_types.WGPUTextureFormat_BGRA8Unorm,
    format: model_gpu_types.WGPUTextureFormat = model_gpu_types.WGPUTextureFormat_RGBA8Unorm,
    usage: model_gpu_types.WGPUFlags = model_gpu_types.WGPUTextureUsage_RenderAttachment,
    alpha_mode: u32 = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    present_mode: u32 = WGPU_PRESENT_MODE_FIFO,
    tone_mapping_mode: u32 = WGPU_CANVAS_TONE_MAPPING_MODE_STANDARD,
    desired_maximum_frame_latency: u32 = DEFAULT_SURFACE_MAX_FRAME_LATENCY,
    last_acquire_suboptimal: bool = false,
    last_present_suboptimal: bool = false,
    // Cached capabilities
    capabilities_queried: bool = false,
    cached_capabilities: SurfaceCapabilities = .{},
};
// -- Instance extension names required for surface creation --

pub const INSTANCE_SURFACE_EXTENSION: [*:0]const u8 = "VK_KHR_surface";
pub const INSTANCE_WAYLAND_EXTENSION: [*:0]const u8 = "VK_KHR_wayland_surface";
pub const INSTANCE_XCB_EXTENSION: [*:0]const u8 = "VK_KHR_xcb_surface";
pub const INSTANCE_XLIB_EXTENSION: [*:0]const u8 = "VK_KHR_xlib_surface";
pub const DEVICE_SWAPCHAIN_EXTENSION: [*:0]const u8 = "VK_KHR_swapchain";
pub const WGPU_CANVAS_TONE_MAPPING_MODE_STANDARD: u32 = 0x00000001;
pub const WGPU_CANVAS_TONE_MAPPING_MODE_EXTENDED: u32 = 0x00000002;
/// Returns instance extensions needed for surface support on this platform.
pub fn required_instance_extensions() []const [*:0]const u8 {
    if (!is_linux) return &[_][*:0]const u8{};
    // Both Wayland and XCB are common; request both so the runtime can
    // create surfaces for whichever compositor is active.
    return &[_][*:0]const u8{
        INSTANCE_SURFACE_EXTENSION,
        INSTANCE_WAYLAND_EXTENSION,
        INSTANCE_XCB_EXTENSION,
        INSTANCE_XLIB_EXTENSION,
    };
}
/// Returns device extensions needed for swapchain support.
pub fn required_device_extensions() []const [*:0]const u8 {
    if (!is_linux) return &[_][*:0]const u8{};
    return &[_][*:0]const u8{
        DEVICE_SWAPCHAIN_EXTENSION,
    };
}
/// Create a VkSurfaceKHR from a Wayland display+surface pair.
pub fn create_wayland_surface(
    instance: VkInstance,
    wl_display: ?*anyopaque,
    wl_surface: ?*anyopaque,
) common_errors.BackendNativeError!VkSurfaceKHR {
    if (!is_linux) return error.UnsupportedFeature;
    if (wl_display == null or wl_surface == null) return error.InvalidArgument;
    var surface: VkSurfaceKHR = VK_NULL_U64;
    const create_info = VkWaylandSurfaceCreateInfoKHR{
        .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .display = wl_display,
        .surface = wl_surface,
    };
    try check_vk(vkCreateWaylandSurfaceKHR(instance, &create_info, null, &surface));
    if (surface == VK_NULL_U64) return error.InvalidState;
    return surface;
}

/// Create a VkSurfaceKHR from an XCB connection+window pair.
pub fn create_xcb_surface(
    instance: VkInstance,
    xcb_connection: ?*anyopaque,
    xcb_window: u32,
) common_errors.BackendNativeError!VkSurfaceKHR {
    if (!is_linux) return error.UnsupportedFeature;
    if (xcb_connection == null) return error.InvalidArgument;

    var surface: VkSurfaceKHR = VK_NULL_U64;
    const create_info = VkXcbSurfaceCreateInfoKHR{
        .sType = VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .connection = xcb_connection,
        .window = xcb_window,
    };
    try check_vk(vkCreateXcbSurfaceKHR(instance, &create_info, null, &surface));
    if (surface == VK_NULL_U64) return error.InvalidState;
    return surface;
}

/// Create a VkSurfaceKHR from an Xlib display+window pair.
pub fn create_xlib_surface(
    instance: VkInstance,
    xlib_display: ?*anyopaque,
    xlib_window: u64,
) common_errors.BackendNativeError!VkSurfaceKHR {
    if (!is_linux) return error.UnsupportedFeature;
    if (xlib_display == null) return error.InvalidArgument;

    var surface: VkSurfaceKHR = VK_NULL_U64;
    const create_info = VkXlibSurfaceCreateInfoKHR{
        .sType = VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .dpy = xlib_display,
        .window = xlib_window,
    };
    try check_vk(vkCreateXlibSurfaceKHR(instance, &create_info, null, &surface));
    if (surface == VK_NULL_U64) return error.InvalidState;
    return surface;
}

/// Destroy a VkSurfaceKHR.
pub fn destroy_surface(instance: VkInstance, surface: VkSurfaceKHR) void {
    if (surface != VK_NULL_U64) {
        vkDestroySurfaceKHR(instance, surface, null);
    }
}

/// Query whether a queue family supports presentation to a given surface.
pub fn query_present_support(
    physical_device: VkPhysicalDevice,
    queue_family_index: u32,
    surface: VkSurfaceKHR,
) common_errors.BackendNativeError!bool {
    if (surface == VK_NULL_U64) return false;
    var supported: VkBool32 = VK_FALSE;
    try check_vk(vkGetPhysicalDeviceSurfaceSupportKHR(
        physical_device,
        queue_family_index,
        surface,
        &supported,
    ));
    return supported == VK_TRUE;
}

/// Query full surface capabilities, formats, and present modes.
pub fn query_surface_capabilities(
    physical_device: VkPhysicalDevice,
    queue_family_index: u32,
    surface: VkSurfaceKHR,
) common_errors.BackendNativeError!SurfaceCapabilities {
    if (surface == VK_NULL_U64) return error.SurfaceUnavailable;

    var result = SurfaceCapabilities{};

    // Present support
    result.present_supported = try query_present_support(
        physical_device,
        queue_family_index,
        surface,
    );

    // Surface capabilities
    var caps = std.mem.zeroes(VkSurfaceCapabilitiesKHR);
    try check_vk(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &caps));
    result.min_image_count = caps.minImageCount;
    result.max_image_count = caps.maxImageCount;
    result.current_width = caps.currentExtent.width;
    result.current_height = caps.currentExtent.height;
    result.min_width = caps.minImageExtent.width;
    result.min_height = caps.minImageExtent.height;
    result.max_width = caps.maxImageExtent.width;
    result.max_height = caps.maxImageExtent.height;
    result.supported_usage = caps.supportedUsageFlags;

    // Surface formats
    var format_count: u32 = 0;
    try check_vk(vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null));
    if (format_count > 0) {
        const capped_count = @min(format_count, MAX_SURFACE_FORMATS);
        var count_for_query: u32 = @intCast(capped_count);
        try check_vk(vkGetPhysicalDeviceSurfaceFormatsKHR(
            physical_device,
            surface,
            &count_for_query,
            &result.formats,
        ));
        result.format_count = count_for_query;
    }

    // Present modes
    var mode_count: u32 = 0;
    try check_vk(vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &mode_count, null));
    if (mode_count > 0) {
        const capped_modes = @min(mode_count, MAX_PRESENT_MODES);
        var count_for_mode_query: u32 = @intCast(capped_modes);
        try check_vk(vkGetPhysicalDeviceSurfacePresentModesKHR(
            physical_device,
            surface,
            &count_for_mode_query,
            &result.present_modes,
        ));
        result.present_mode_count = count_for_mode_query;
    }

    return result;
}

/// Create synchronization semaphores needed for swapchain acquire/present.
pub fn create_sync_objects(device: VkDevice) common_errors.BackendNativeError!struct { image_available: VkSemaphore, render_finished: VkSemaphore } {
    const sem_info = VkSemaphoreCreateInfo{
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };
    var image_available: VkSemaphore = VK_NULL_U64;
    try check_vk(vkCreateSemaphore(device, &sem_info, null, &image_available));
    errdefer if (image_available != VK_NULL_U64) vkDestroySemaphore(device, image_available, null);

    var render_finished: VkSemaphore = VK_NULL_U64;
    try check_vk(vkCreateSemaphore(device, &sem_info, null, &render_finished));

    return .{
        .image_available = image_available,
        .render_finished = render_finished,
    };
}

/// Destroy synchronization semaphores.
pub fn destroy_sync_objects(
    device: VkDevice,
    image_available: VkSemaphore,
    render_finished: VkSemaphore,
) void {
    if (image_available != VK_NULL_U64) vkDestroySemaphore(device, image_available, null);
    if (render_finished != VK_NULL_U64) vkDestroySemaphore(device, render_finished, null);
}

/// Select the best surface format from available formats.
fn select_surface_format(
    formats: []const VkSurfaceFormatKHR,
    requested_format: model_gpu_types.WGPUTextureFormat,
    tone_mapping_mode: u32,
) VkSurfaceFormatKHR {
    if (tone_mapping_mode == WGPU_CANVAS_TONE_MAPPING_MODE_EXTENDED) {
        for (formats) |fmt| {
            if (fmt.colorSpace == VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT and
                fmt.format == VK_FORMAT_R16G16B16A16_SFLOAT)
            {
                return fmt;
            }
        }
        for (formats) |fmt| {
            if (fmt.colorSpace == VK_COLOR_SPACE_EXTENDED_SRGB_LINEAR_EXT) return fmt;
        }
    }
    if (requested_format == model_gpu_types.WGPUTextureFormat_BGRA8Unorm) {
        for (formats) |fmt| {
            if (fmt.format == VK_FORMAT_B8G8R8A8_UNORM and
                fmt.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                return fmt;
            }
        }
    }
    if (requested_format == model_gpu_types.WGPUTextureFormat_RGBA8Unorm) {
        for (formats) |fmt| {
            if (fmt.format == VK_FORMAT_R8G8B8A8_UNORM and
                fmt.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                return fmt;
            }
        }
    }
    if (requested_format == model_gpu_types.WGPUTextureFormat_BGRA8UnormSrgb) {
        for (formats) |fmt| {
            if (fmt.format == VK_FORMAT_B8G8R8A8_SRGB and
                fmt.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                return fmt;
            }
        }
    }
    if (requested_format == model_gpu_types.WGPUTextureFormat_RGBA8UnormSrgb) {
        for (formats) |fmt| {
            if (fmt.format == VK_FORMAT_R8G8B8A8_UNORM and
                fmt.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                return fmt;
            }
        }
    }
    for (formats) |fmt| {
        if (fmt.format == VK_FORMAT_B8G8R8A8_SRGB and
            fmt.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return fmt;
        }
    }
    // Fall back to B8G8R8A8_UNORM
    for (formats) |fmt| {
        if (fmt.format == VK_FORMAT_B8G8R8A8_UNORM) return fmt;
    }
    // Fall back to R8G8B8A8_UNORM
    for (formats) |fmt| {
        if (fmt.format == VK_FORMAT_R8G8B8A8_UNORM) return fmt;
    }
    // Last resort: use whatever the driver offers first
    if (formats.len > 0) return formats[0];
    return .{ .format = VK_FORMAT_B8G8R8A8_SRGB, .colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR };
}

pub fn preferred_canvas_format_from_surface_formats(formats: []const VkSurfaceFormatKHR) model_gpu_types.WGPUTextureFormat {
    for (formats) |fmt| {
        if (fmt.format == VK_FORMAT_B8G8R8A8_UNORM and fmt.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            return model_gpu_types.WGPUTextureFormat_BGRA8Unorm;
        }
    }
    for (formats) |fmt| {
        if (fmt.format == VK_FORMAT_R8G8B8A8_UNORM and fmt.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            return model_gpu_types.WGPUTextureFormat_RGBA8Unorm;
        }
    }
    for (formats) |fmt| {
        if (fmt.format == VK_FORMAT_B8G8R8A8_SRGB and fmt.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            return model_gpu_types.WGPUTextureFormat_BGRA8Unorm;
        }
    }
    for (formats) |fmt| {
        if (fmt.format == VK_FORMAT_R8G8B8A8_UNORM) return model_gpu_types.WGPUTextureFormat_RGBA8Unorm;
        if (fmt.format == VK_FORMAT_B8G8R8A8_UNORM) return model_gpu_types.WGPUTextureFormat_BGRA8Unorm;
    }
    return model_gpu_types.WGPUTextureFormat_BGRA8Unorm;
}

fn canvas_format_for_selected_surface_format(
    requested_format: model_gpu_types.WGPUTextureFormat,
    selected_format: VkSurfaceFormatKHR,
) model_gpu_types.WGPUTextureFormat {
    switch (selected_format.format) {
        VK_FORMAT_B8G8R8A8_UNORM => return model_gpu_types.WGPUTextureFormat_BGRA8Unorm,
        VK_FORMAT_B8G8R8A8_SRGB => return if (requested_format == model_gpu_types.WGPUTextureFormat_BGRA8UnormSrgb)
            model_gpu_types.WGPUTextureFormat_BGRA8UnormSrgb
        else
            model_gpu_types.WGPUTextureFormat_BGRA8Unorm,
        VK_FORMAT_R8G8B8A8_UNORM => return model_gpu_types.WGPUTextureFormat_RGBA8Unorm,
        VK_FORMAT_R16G16B16A16_SFLOAT => return requested_format,
        else => return requested_format,
    }
}

/// Map WebGPU present mode to Vulkan present mode.
fn map_present_mode(wgpu_mode: u32) u32 {
    return switch (wgpu_mode) {
        WGPU_PRESENT_MODE_FIFO => VK_PRESENT_MODE_FIFO_KHR,
        WGPU_PRESENT_MODE_MAILBOX => VK_PRESENT_MODE_MAILBOX_KHR,
        WGPU_PRESENT_MODE_IMMEDIATE => VK_PRESENT_MODE_IMMEDIATE_KHR,
        else => VK_PRESENT_MODE_FIFO_KHR,
    };
}

/// Map the requested WebGPU alpha mode to a Vulkan composite-alpha mode.
fn map_composite_alpha(requested: u32, supported: VkFlags) u32 {
    const requested_mode: u32 = switch (requested) {
        VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR, VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR, VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR => requested,
        else => VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    };
    if ((supported & requested_mode) != 0) return requested_mode;
    if ((supported & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR) != 0) return VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if ((supported & VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR) != 0) return VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
    if ((supported & VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR) != 0) return VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR;
    if ((supported & VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR) != 0) return VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
    return VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
}

/// Clamp the requested extent to the surface capabilities.
fn clamp_extent(
    requested_width: u32,
    requested_height: u32,
    caps: VkSurfaceCapabilitiesKHR,
) VkExtent2D {
    // 0xFFFFFFFF means the surface size is determined by the swapchain extent
    const SPECIAL_EXTENT: u32 = 0xFFFFFFFF;
    if (caps.currentExtent.width != SPECIAL_EXTENT) return caps.currentExtent;
    return .{
        .width = std.math.clamp(requested_width, caps.minImageExtent.width, caps.maxImageExtent.width),
        .height = std.math.clamp(requested_height, caps.minImageExtent.height, caps.maxImageExtent.height),
    };
}

fn map_surface_usage_flags(wgpu_usage: model_gpu_types.WGPUFlags) VkFlags {
    var usage: VkFlags = 0;
    if ((wgpu_usage & model_gpu_types.WGPUTextureUsage_RenderAttachment) != 0) usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if ((wgpu_usage & model_gpu_types.WGPUTextureUsage_CopySrc) != 0) usage |= VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if ((wgpu_usage & model_gpu_types.WGPUTextureUsage_CopyDst) != 0) usage |= VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if ((wgpu_usage & model_gpu_types.WGPUTextureUsage_TextureBinding) != 0) usage |= VK_IMAGE_USAGE_SAMPLED_BIT;
    if (usage == 0) usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    return usage;
}

/// Create (or recreate) a swapchain for the given surface.
pub fn create_swapchain(
    device: VkDevice,
    physical_device: VkPhysicalDevice,
    surface_state: *VulkanSurface,
    queue_family_index: u32,
) common_errors.BackendNativeError!void {
    if (surface_state.vk_surface == VK_NULL_U64) return error.SurfaceUnavailable;

    // Query capabilities for swapchain creation
    var caps = std.mem.zeroes(VkSurfaceCapabilitiesKHR);
    try check_vk(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
        physical_device,
        surface_state.vk_surface,
        &caps,
    ));

    // Query formats
    var format_count: u32 = 0;
    try check_vk(vkGetPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        surface_state.vk_surface,
        &format_count,
        null,
    ));
    if (format_count == 0) return error.SurfaceUnavailable;

    var formats: [MAX_SURFACE_FORMATS]VkSurfaceFormatKHR = std.mem.zeroes([MAX_SURFACE_FORMATS]VkSurfaceFormatKHR);
    var query_format_count: u32 = @intCast(@min(format_count, MAX_SURFACE_FORMATS));
    try check_vk(vkGetPhysicalDeviceSurfaceFormatsKHR(
        physical_device,
        surface_state.vk_surface,
        &query_format_count,
        &formats,
    ));

    const chosen_format = select_surface_format(
        formats[0..@as(usize, query_format_count)],
        surface_state.requested_format,
        surface_state.tone_mapping_mode,
    );
    const chosen_present_mode = map_present_mode(surface_state.present_mode);
    const chosen_alpha_mode = map_composite_alpha(surface_state.alpha_mode, caps.supportedCompositeAlpha);
    const chosen_extent = clamp_extent(surface_state.width, surface_state.height, caps);
    const requested_usage = map_surface_usage_flags(surface_state.usage);
    if ((requested_usage & caps.supportedUsageFlags) != requested_usage) return error.UnsupportedFeature;

    // Image count: prefer one more than minimum for triple buffering
    var image_count: u32 = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) {
        image_count = caps.maxImageCount;
    }

    const old_swapchain = surface_state.swapchain;

    const create_info = VkSwapchainCreateInfoKHR{
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .surface = surface_state.vk_surface,
        .minImageCount = image_count,
        .imageFormat = chosen_format.format,
        .imageColorSpace = chosen_format.colorSpace,
        .imageExtent = chosen_extent,
        .imageArrayLayers = 1,
        .imageUsage = requested_usage,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 1,
        .pQueueFamilyIndices = @ptrCast(&queue_family_index),
        .preTransform = caps.currentTransform,
        .compositeAlpha = chosen_alpha_mode,
        .presentMode = chosen_present_mode,
        .clipped = VK_TRUE,
        .oldSwapchain = old_swapchain,
    };

    try check_vk(vkCreateSwapchainKHR(device, &create_info, null, &surface_state.swapchain));

    // Destroy old swapchain after new one is created
    if (old_swapchain != VK_NULL_U64) {
        vkDestroySwapchainKHR(device, old_swapchain, null);
    }

    // Retrieve swapchain images
    var actual_image_count: u32 = 0;
    try check_vk(vkGetSwapchainImagesKHR(device, surface_state.swapchain, &actual_image_count, null));
    if (actual_image_count == 0) return error.InvalidState;
    if (actual_image_count > MAX_SWAPCHAIN_IMAGES) return error.InvalidState;
    try check_vk(vkGetSwapchainImagesKHR(
        device,
        surface_state.swapchain,
        &actual_image_count,
        &surface_state.swapchain_images,
    ));
    surface_state.swapchain_image_count = actual_image_count;
    surface_state.swapchain_format = chosen_format.format;
    surface_state.swapchain_extent = chosen_extent;
    surface_state.format = canvas_format_for_selected_surface_format(surface_state.requested_format, chosen_format);
    surface_state.last_acquire_suboptimal = false;
    surface_state.last_present_suboptimal = false;

    // Create sync objects if not yet created
    if (surface_state.image_available_semaphore == VK_NULL_U64) {
        const sync = try create_sync_objects(device);
        surface_state.image_available_semaphore = sync.image_available;
        surface_state.render_finished_semaphore = sync.render_finished;
    }
}

/// Destroy the swapchain and associated resources (not the VkSurfaceKHR itself).
pub fn destroy_swapchain(device: VkDevice, surface_state: *VulkanSurface) void {
    if (surface_state.swapchain != VK_NULL_U64) {
        vkDestroySwapchainKHR(device, surface_state.swapchain, null);
        surface_state.swapchain = VK_NULL_U64;
    }
    surface_state.swapchain_image_count = 0;
    surface_state.swapchain_images = [_]VkImage{VK_NULL_U64} ** MAX_SWAPCHAIN_IMAGES;
    surface_state.swapchain_extent = .{ .width = 0, .height = 0 };
}

/// Acquire the next swapchain image. Returns the image index.
pub fn acquire_next_image(
    device: VkDevice,
    surface_state: *VulkanSurface,
) common_errors.BackendNativeError!u32 {
    if (surface_state.swapchain == VK_NULL_U64) return error.SurfaceUnavailable;

    var image_index: u32 = 0;
    const result = vkAcquireNextImageKHR(
        device,
        surface_state.swapchain,
        ACQUIRE_TIMEOUT_NS,
        surface_state.image_available_semaphore,
        VK_NULL_U64,
        &image_index,
    );
    switch (result) {
        VK_SUCCESS, VK_SUBOPTIMAL_KHR => {
            surface_state.current_image_index = image_index;
            surface_state.acquired = true;
            surface_state.last_acquire_suboptimal = result == VK_SUBOPTIMAL_KHR;
            return image_index;
        },
        VK_ERROR_OUT_OF_DATE_KHR => {
            // Swapchain needs recreation; caller should reconfigure
            return error.SurfaceUnavailable;
        },
        else => {
            try check_vk(result);
            unreachable;
        },
    }
}

/// Present the acquired swapchain image.
pub fn present_image(
    queue: VkQueue,
    surface_state: *VulkanSurface,
) common_errors.BackendNativeError!void {
    if (surface_state.swapchain == VK_NULL_U64 or !surface_state.acquired) {
        return error.SurfaceUnavailable;
    }

    const present_info = VkPresentInfoKHR{
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .swapchainCount = 1,
        .pSwapchains = @ptrCast(&surface_state.swapchain),
        .pImageIndices = @ptrCast(&surface_state.current_image_index),
        .pResults = null,
    };

    const result = vkQueuePresentKHR(queue, &present_info);
    surface_state.acquired = false;
    surface_state.last_present_suboptimal = result == VK_SUBOPTIMAL_KHR;

    switch (result) {
        VK_SUCCESS, VK_SUBOPTIMAL_KHR => return,
        VK_ERROR_OUT_OF_DATE_KHR => {
            // Swapchain will need recreation on next configure
            return;
        },
        else => return check_vk(result),
    }
}

/// Full cleanup of a VulkanSurface: swapchain, sync objects, and the surface itself.
pub fn destroy_all(
    instance: VkInstance,
    device: VkDevice,
    surface_state: *VulkanSurface,
) void {
    destroy_sync_objects(
        device,
        surface_state.image_available_semaphore,
        surface_state.render_finished_semaphore,
    );
    surface_state.image_available_semaphore = VK_NULL_U64;
    surface_state.render_finished_semaphore = VK_NULL_U64;

    destroy_swapchain(device, surface_state);
    destroy_surface(instance, surface_state.vk_surface);
    surface_state.vk_surface = VK_NULL_U64;
    surface_state.configured = false;
    surface_state.acquired = false;
}

// Delegate to vulkan_errors.zig — single source of truth for VkResult mapping.
const check_vk = vulkan_errors.check_vk;
