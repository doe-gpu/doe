// doe_surface_native.zig — WebGPU Surface C ABI for the Doe Vulkan backend.
//
// Metal surfaces are not exposed through this ABI (Metal uses CAMetalLayer natively).
// Vulkan path routes lifecycle calls to NativeVulkanRuntime surface methods.
//
// Platform VkSurface handles (XCB/Wayland/Xlib) must be attached via
// doeNativeSurfaceSetXcbHandle / doeNativeSurfaceSetWaylandHandle / doeNativeSurfaceSetXlibHandle before
// doeNativeSurfaceConfigure is called to enable a real VkSwapchainKHR.
// Headless placeholder presentation is not allowed on this path; configure
// and acquire fail explicitly until a real platform surface is attached.

const std = @import("std");
const log = std.log.scoped(.doe_surface_native);
const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const backend_surface_ops = @import("../../backend/dropin_surface_ops.zig");
const backend_resource_ops = @import("../../backend/dropin_resource_ops.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const native_rt_helpers = @import("../support/doe_native_runtime_helpers.zig");
const vk_surf = backend_surface_ops;
const vk_constants = if (has_vulkan) backend_resource_ops.vk_constants else struct {};
const vk_resources = if (has_vulkan) backend_resource_ops.vk_resources else struct {};
const vulkan_texture_native = @import("../vulkan/vulkan_texture_native.zig");

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_surface_control_types = @import("../../contracts/model/model_surface_control_types.zig");

const DoeDevice = native_types.DoeDevice;
const DoeInstance = native_types.DoeInstance;
const DoeTexture = native_types.DoeTexture;
const NativeVulkanRuntime = native_shared.NativeVulkanRuntime;

const MAGIC_SURFACE: u32 = 0xD0E1_0013;
const MAX_SURFACE_DESCRIPTOR_CHAIN_NODES: u32 = 16;

const WGPU_SURFACE_GET_CURRENT_TEXTURE_STATUS_SUCCESS: u32 = 0x00000001;
const WGPU_SURFACE_GET_CURRENT_TEXTURE_STATUS_TIMEOUT: u32 = 0x00000003;

pub const DoeSurface = struct {
    pub const TYPE_MAGIC = MAGIC_SURFACE;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    backend: native_shared.BackendKind = .metal,
    handle: u64 = 0,
    instance_ref: ?*DoeInstance = null,
    vk_runtime_ref: ?*anyopaque = null,
    current_tex: ?*DoeTexture = null,
    pending_xcb_connection: ?*anyopaque = null,
    pending_xcb_window: u32 = 0,
    pending_wayland_display: ?*anyopaque = null,
    pending_wayland_surface: ?*anyopaque = null,
    pending_xlib_display: ?*anyopaque = null,
    pending_xlib_window: u64 = 0,
};

const surface_procs = @import("../../full/surface/wgpu_surface_procs.zig");

fn retain_surface_instance(surf: *DoeSurface, inst_raw: ?*anyopaque) void {
    if (cast(DoeInstance, inst_raw)) |inst| {
        native_helpers.object_add_ref(DoeInstance, inst_raw);
        surf.instance_ref = inst;
    }
}

fn release_surface_instance(surf: *DoeSurface) void {
    if (surf.instance_ref) |inst| {
        @import("../lifecycle/doe_instance_device_native.zig").doeNativeInstanceRelease(toOpaque(inst));
        surf.instance_ref = null;
    }
}

fn capture_surface_descriptor(surf: *DoeSurface, desc_raw: ?*anyopaque) void {
    const raw = desc_raw orelse return;
    const desc: *const surface_procs.SurfaceDescriptor = @ptrCast(@alignCast(raw));
    var chain = desc.nextInChain;
    var visited: u32 = 0;
    while (chain) |node| : (visited += 1) {
        if (visited >= MAX_SURFACE_DESCRIPTOR_CHAIN_NODES) return;
        switch (node.sType) {
            surface_procs.SurfaceSourceXCBWindowSType => {
                const source: *const surface_procs.SurfaceSourceXCBWindow = @ptrCast(@alignCast(node));
                surf.pending_xcb_connection = source.connection;
                surf.pending_xcb_window = source.window;
            },
            surface_procs.SurfaceSourceWaylandSurfaceSType => {
                const source: *const surface_procs.SurfaceSourceWaylandSurface = @ptrCast(@alignCast(node));
                surf.pending_wayland_display = source.display;
                surf.pending_wayland_surface = source.surface;
            },
            surface_procs.SurfaceSourceXlibWindowSType => {
                const source: *const surface_procs.SurfaceSourceXlibWindow = @ptrCast(@alignCast(node));
                surf.pending_xlib_display = source.display;
                surf.pending_xlib_window = source.window;
            },
            else => {},
        }
        chain = node.next;
    }
}

fn attach_xcb_surface(surf: *DoeSurface, rt: *NativeVulkanRuntime) bool {
    if (surf.pending_xcb_connection == null) return false;
    const state = rt.surfaces.getPtr(surf.handle) orelse return false;
    if (state.vk_surface != 0) return true;
    const vk_handle = vk_surf.create_xcb_surface(rt.instance, surf.pending_xcb_connection, surf.pending_xcb_window) catch |err| {
        std.log.err("doe_surface_native: create_xcb_surface failed: {s}", .{@errorName(err)});
        return false;
    };
    state.vk_surface = vk_handle;
    state.platform = .xcb;
    return true;
}

fn attach_wayland_surface(surf: *DoeSurface, rt: *NativeVulkanRuntime) bool {
    if (surf.pending_wayland_display == null or surf.pending_wayland_surface == null) return false;
    const state = rt.surfaces.getPtr(surf.handle) orelse return false;
    if (state.vk_surface != 0) return true;
    const vk_handle = vk_surf.create_wayland_surface(rt.instance, surf.pending_wayland_display, surf.pending_wayland_surface) catch |err| {
        std.log.err("doe_surface_native: create_wayland_surface failed: {s}", .{@errorName(err)});
        return false;
    };
    state.vk_surface = vk_handle;
    state.platform = .wayland;
    return true;
}

fn attach_xlib_surface(surf: *DoeSurface, rt: *NativeVulkanRuntime) bool {
    if (surf.pending_xlib_display == null) return false;
    const state = rt.surfaces.getPtr(surf.handle) orelse return false;
    if (state.vk_surface != 0) return true;
    const vk_handle = vk_surf.create_xlib_surface(rt.instance, surf.pending_xlib_display, surf.pending_xlib_window) catch |err| {
        std.log.err("doe_surface_native: create_xlib_surface failed: {s}", .{@errorName(err)});
        return false;
    };
    state.vk_surface = vk_handle;
    state.platform = .xlib;
    return true;
}

fn attach_pending_platform_surface(surf: *DoeSurface, rt: *NativeVulkanRuntime) bool {
    if (attach_xcb_surface(surf, rt)) return true;
    if (attach_wayland_surface(surf, rt)) return true;
    if (attach_xlib_surface(surf, rt)) return true;
    return false;
}

fn bind_surface_runtime(surf: *DoeSurface, dev_raw: ?*anyopaque) bool {
    const dev = cast(DoeDevice, dev_raw) orelse return false;
    if (dev.backend != .vulkan) return false;
    const rt = native_rt_helpers.device_vk_runtime(dev) orelse return false;
    const rt_opaque: *anyopaque = @ptrCast(rt);
    if (surf.vk_runtime_ref) |existing| {
        if (existing != rt_opaque) {
            std.log.err("doe_surface_native: surface configured with a different Vulkan runtime", .{});
            return false;
        }
        _ = attach_pending_platform_surface(surf, rt);
        return true;
    }

    rt.create_surface(surf.handle) catch |err| {
        std.log.err("doe_surface_native: create_surface failed: {s}", .{@errorName(err)});
        return false;
    };
    surf.vk_runtime_ref = rt_opaque;
    _ = attach_pending_platform_surface(surf, rt);
    return true;
}

fn release_current_surface_texture(surf: *DoeSurface) void {
    if (surf.current_tex) |tex| {
        vulkan_texture_native.vulkan_destroy_texture(tex);
        alloc.destroy(tex);
        surf.current_tex = null;
    }
}

fn register_acquired_surface_texture(
    rt: *NativeVulkanRuntime,
    surface_state: *const backend_surface_ops.VulkanSurface,
    tex: *DoeTexture,
) bool {
    const image_count: usize = @intCast(surface_state.swapchain_image_count);
    const image_index: usize = @intCast(surface_state.current_image_index);
    if (image_index >= image_count) return false;
    const image = surface_state.swapchain_images[image_index];
    if (image == 0) return false;

    const handle: u64 = @intFromPtr(tex);
    const resource = vk_resources.borrowed_texture_resource(
        image,
        surface_state.swapchain_extent.width,
        surface_state.swapchain_extent.height,
        1,
        1,
        1,
        model_gpu_types.WGPUTextureDimension_2D,
        model_gpu_types.WGPUTextureViewDimension_2D,
        model_gpu_types.WGPUTextureAspect_All,
        surface_state.format,
        surface_state.usage,
        vk_constants.VK_IMAGE_LAYOUT_UNDEFINED,
    );
    const result = rt.textures.getOrPut(rt.allocator, handle) catch return false;
    if (result.found_existing) {
        vk_resources.release_texture_resource(rt, result.value_ptr.*);
    }
    result.value_ptr.* = resource;
    tex.vk_id = handle;
    return true;
}

// ============================================================
// Instance: createSurface
// ============================================================

/// Create an unconfigured Vulkan surface and retain the originating instance.
/// Device/runtime binding happens at configure time via SurfaceConfiguration.device.
pub export fn doeNativeInstanceCreateSurface(
    inst_raw: ?*anyopaque,
    desc_raw: ?*anyopaque,
    dev_raw: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    if (comptime !has_vulkan) return null;

    const surf = make(DoeSurface) orelse return null;
    const handle: u64 = @intFromPtr(surf);
    surf.* = .{
        .backend = .vulkan,
        .handle = handle,
    };
    retain_surface_instance(surf, inst_raw);
    capture_surface_descriptor(surf, desc_raw);

    if (dev_raw != null and !bind_surface_runtime(surf, dev_raw)) {
        release_surface_instance(surf);
        alloc.destroy(surf);
        return null;
    }
    return toOpaque(surf);
}

// ============================================================
// Platform VkSurface handle setters
// Must be called before doeNativeSurfaceConfigure for windowed rendering.
// ============================================================

/// Attach an XCB window to the surface. Enables real swapchain on Linux.
pub export fn doeNativeSurfaceSetXcbHandle(
    surf_raw: ?*anyopaque,
    xcb_connection: ?*anyopaque,
    xcb_window: u32,
) callconv(.c) void {
    if (comptime !has_vulkan) return;
    const surf = cast(DoeSurface, surf_raw) orelse return;
    if (surf.backend != .vulkan) return;
    surf.pending_xcb_connection = xcb_connection;
    surf.pending_xcb_window = xcb_window;
    const rt_ptr = surf.vk_runtime_ref orelse return;
    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
    _ = attach_xcb_surface(surf, rt);
}

/// Attach a Wayland surface to the surface. Enables real swapchain on Linux.
pub export fn doeNativeSurfaceSetWaylandHandle(
    surf_raw: ?*anyopaque,
    wl_display: ?*anyopaque,
    wl_surface: ?*anyopaque,
) callconv(.c) void {
    if (comptime !has_vulkan) return;
    const surf = cast(DoeSurface, surf_raw) orelse return;
    if (surf.backend != .vulkan) return;
    surf.pending_wayland_display = wl_display;
    surf.pending_wayland_surface = wl_surface;
    const rt_ptr = surf.vk_runtime_ref orelse return;
    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
    _ = attach_wayland_surface(surf, rt);
}

/// Attach an Xlib window to the surface. Enables real swapchain on Linux.
pub export fn doeNativeSurfaceSetXlibHandle(
    surf_raw: ?*anyopaque,
    xlib_display: ?*anyopaque,
    xlib_window: u64,
) callconv(.c) void {
    if (comptime !has_vulkan) return;
    const surf = cast(DoeSurface, surf_raw) orelse return;
    if (surf.backend != .vulkan) return;
    surf.pending_xlib_display = xlib_display;
    surf.pending_xlib_window = xlib_window;
    const rt_ptr = surf.vk_runtime_ref orelse return;
    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
    _ = attach_xlib_surface(surf, rt);
}

// ============================================================
// Surface configure / acquire / present / unconfigure / release
// ============================================================

pub export fn doeNativeSurfaceConfigure(
    surf_raw: ?*anyopaque,
    width: u32,
    height: u32,
    format: u32,
    usage: u32,
    alpha_mode: u32,
    present_mode: u32,
    tone_mapping_mode: u32,
) callconv(.c) void {
    doeNativeSurfaceConfigureForDevice(
        surf_raw,
        null,
        width,
        height,
        format,
        usage,
        alpha_mode,
        present_mode,
        tone_mapping_mode,
    );
}

fn doeNativeSurfaceConfigureForDevice(
    surf_raw: ?*anyopaque,
    dev_raw: ?*anyopaque,
    width: u32,
    height: u32,
    format: u32,
    usage: u32,
    alpha_mode: u32,
    present_mode: u32,
    tone_mapping_mode: u32,
) void {
    if (comptime !has_vulkan) return;
    const surf = cast(DoeSurface, surf_raw) orelse return;
    if (surf.backend != .vulkan) return;
    if (surf.vk_runtime_ref == null and !bind_surface_runtime(surf, dev_raw)) {
        std.log.err("doe_surface_native: configure_surface failed: missing Vulkan device binding", .{});
        return;
    }
    const rt_ptr = surf.vk_runtime_ref orelse return;
    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
    rt.configure_surface(model_surface_control_types.SurfaceConfigureCommand{
        .handle = surf.handle,
        .width = width,
        .height = height,
        .format = format,
        .usage = usage,
        .alpha_mode = alpha_mode,
        .present_mode = present_mode,
        .tone_mapping_mode = tone_mapping_mode,
    }) catch |err| {
        std.log.err("doe_surface_native: configure_surface failed: {s}", .{@errorName(err)});
    };
}

/// Acquire the next swapchain image and expose it as a WGPUTexture handle.
pub export fn doeNativeSurfaceGetCurrentTexture(
    surf_raw: ?*anyopaque,
    out_texture: ?*?*anyopaque,
    out_suboptimal: ?*u32,
    out_status: ?*u32,
) callconv(.c) void {
    if (out_status) |s| s.* = WGPU_SURFACE_GET_CURRENT_TEXTURE_STATUS_TIMEOUT;
    if (out_suboptimal) |s| s.* = 0;
    if (out_texture) |t| t.* = null;
    if (comptime !has_vulkan) return;

    const surf = cast(DoeSurface, surf_raw) orelse return;
    if (surf.backend != .vulkan) return;
    const rt_ptr = surf.vk_runtime_ref orelse return;
    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));

    rt.acquire_surface(surf.handle) catch |err| {
        std.log.err("doe_surface_native: acquire_surface failed: {s}", .{@errorName(err)});
        return;
    };

    const surface_state = rt.surfaces.getPtr(surf.handle) orelse return;

    release_current_surface_texture(surf);
    const tex = make(DoeTexture) orelse return;
    tex.* = .{
        .backend = .vulkan,
        .format = surface_state.format,
        .width = surface_state.swapchain_extent.width,
        .height = surface_state.swapchain_extent.height,
        .depth_or_array_layers = 1,
        .dimension = model_gpu_types.WGPUTextureDimension_2D,
        .mip_level_count = 1,
        .sample_count = 1,
        .usage = surface_state.usage,
        .texture_binding_view_dimension = model_gpu_types.WGPUTextureViewDimension_2D,
        .vk_runtime_ref = surf.vk_runtime_ref,
    };
    if (!register_acquired_surface_texture(rt, surface_state, tex)) {
        alloc.destroy(tex);
        return;
    }
    surf.current_tex = tex;
    if (out_texture) |t| t.* = toOpaque(tex);
    if (out_suboptimal) |s| s.* = if (surface_state.last_acquire_suboptimal or surface_state.last_present_suboptimal) 1 else 0;
    if (out_status) |s| s.* = WGPU_SURFACE_GET_CURRENT_TEXTURE_STATUS_SUCCESS;
}

pub export fn doeNativeSurfacePresent(surf_raw: ?*anyopaque) callconv(.c) void {
    if (comptime !has_vulkan) return;
    const surf = cast(DoeSurface, surf_raw) orelse return;
    if (surf.backend != .vulkan) return;
    const rt_ptr = surf.vk_runtime_ref orelse return;
    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
    rt.present_surface(surf.handle) catch |err| {
        std.log.err("doe_surface_native: present_surface failed: {s}", .{@errorName(err)});
    };
}

pub export fn doeNativeSurfaceUnconfigure(surf_raw: ?*anyopaque) callconv(.c) void {
    if (comptime !has_vulkan) return;
    const surf = cast(DoeSurface, surf_raw) orelse return;
    if (surf.backend != .vulkan) return;
    const rt_ptr = surf.vk_runtime_ref orelse return;
    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
    rt.unconfigure_surface(surf.handle) catch |err| {
        std.log.err("doe_surface_native: unconfigure_surface failed: {s}", .{@errorName(err)});
    };
    if (surf.current_tex) |tex| {
        _ = tex;
        release_current_surface_texture(surf);
    }
}

pub export fn doeNativeSurfaceRelease(surf_raw: ?*anyopaque) callconv(.c) void {
    if (comptime !has_vulkan) return;
    const surf = cast(DoeSurface, surf_raw) orelse return;
    if (!native_helpers.object_should_destroy(surf)) return;
    if (surf.backend == .vulkan) {
        if (surf.vk_runtime_ref) |rt_ptr| {
            const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
            rt.release_surface(surf.handle) catch |err| {
                log.warn("surface release: {s}", .{@errorName(err)});
            };
        }
    }
    release_current_surface_texture(surf);
    release_surface_instance(surf);
    alloc.destroy(surf);
}

// ============================================================
// Capabilities query
// ============================================================

// Default surface format for Doe Vulkan surfaces.
const DOE_SURFACE_DEFAULT_FORMAT: u32 = model_gpu_types.WGPUTextureFormat_BGRA8Unorm;

// Present mode constants matching WGPUPresentMode values.
const DOE_PRESENT_MODE_FIFO: u32 = 0x00000003;

// Composite alpha mode constants matching WGPUCompositeAlphaMode values.
const DOE_COMPOSITE_ALPHA_MODE_OPAQUE: u32 = 0x00000002;

// Static capability arrays — returned by pointer, never freed.
const DEFAULT_FORMATS = [_]u32{DOE_SURFACE_DEFAULT_FORMAT};
const DEFAULT_PRESENT_MODES = [_]u32{DOE_PRESENT_MODE_FIFO};
const DEFAULT_ALPHA_MODES = [_]u32{DOE_COMPOSITE_ALPHA_MODE_OPAQUE};

/// Minimal capabilities query: reports BGRA8Unorm, Fifo, Opaque.
pub export fn doeNativeSurfaceGetCapabilities(
    surf_raw: ?*anyopaque,
    _: ?*anyopaque,
    out: ?*surface_procs.SurfaceCapabilities,
) callconv(.c) u32 {
    const surf = cast(DoeSurface, surf_raw) orelse return 0;
    _ = surf;
    const caps = out orelse return 0;
    caps.nextInChain = null;
    caps.usages = 0x00000010; // WGPUTextureUsage_RenderAttachment
    caps.formatCount = DEFAULT_FORMATS.len;
    caps.formats = &DEFAULT_FORMATS;
    caps.presentModeCount = DEFAULT_PRESENT_MODES.len;
    caps.presentModes = &DEFAULT_PRESENT_MODES;
    caps.alphaModeCount = DEFAULT_ALPHA_MODES.len;
    caps.alphaModes = &DEFAULT_ALPHA_MODES;
    return 1; // WGPUStatus_Success
}

/// Free members from a capabilities query. Static arrays need no deallocation.
pub export fn doeNativeSurfaceCapabilitiesFreeMembers(_: surface_procs.SurfaceCapabilities) callconv(.c) void {
    // Static arrays — nothing to free.
}

// ============================================================
// ABI bridges: translate WebGPU C ABI struct signatures to
// the flattened parameter signatures used by native functions.
// ============================================================

/// ABI bridge for wgpuInstanceCreateSurface.
/// The native implementation takes an extra dev_raw parameter; the C ABI does not.
/// We pass null for dev_raw (device association happens at configure time).
pub fn doeAbiBridgeInstanceCreateSurface(
    inst_raw: ?*anyopaque,
    desc_raw: *const surface_procs.SurfaceDescriptor,
) callconv(.c) ?*anyopaque {
    return doeNativeInstanceCreateSurface(inst_raw, @ptrCast(@constCast(desc_raw)), null);
}

/// ABI bridge for wgpuSurfaceConfigure.
/// Unpacks SurfaceConfiguration fields into the flattened native call.
pub fn doeAbiBridgeSurfaceConfigure(
    surf_raw: ?*anyopaque,
    config: *const surface_procs.SurfaceConfiguration,
) callconv(.c) void {
    doeNativeSurfaceConfigureForDevice(
        surf_raw,
        config.device,
        config.width,
        config.height,
        config.format,
        @truncate(config.usage), // WGPUTextureUsage is u64; native uses u32
        config.alphaMode,
        config.presentMode,
        0, // tone_mapping_mode — not in C ABI struct; default to standard
    );
}

/// ABI bridge for wgpuSurfaceGetCurrentTexture.
/// Unpacks the SurfaceTexture output struct from the flattened native outputs.
pub fn doeAbiBridgeSurfaceGetCurrentTexture(
    surf_raw: ?*anyopaque,
    out: *surface_procs.SurfaceTexture,
) callconv(.c) void {
    var tex_ptr: ?*anyopaque = null;
    var suboptimal: u32 = 0;
    var status: u32 = 0;
    doeNativeSurfaceGetCurrentTexture(surf_raw, &tex_ptr, &suboptimal, &status);
    out.texture = tex_ptr;
    out.status = status;
}

/// ABI bridge for wgpuSurfacePresent.
/// Native returns void; C ABI expects u32 (WGPUStatus).
pub fn doeAbiBridgeSurfacePresent(surf_raw: ?*anyopaque) callconv(.c) u32 {
    doeNativeSurfacePresent(surf_raw);
    return 1; // WGPUStatus_Success
}
