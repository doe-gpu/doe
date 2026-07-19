// doe_canvas_event_native.zig — Canvas format query and native device event exports.
// Sharded from doe_wgpu_native.zig to keep related surface concerns together.

const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const std = @import("std");
const abi_texture = @import("../../core/abi/wgpu_texture_base_types.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const runtime_helpers = @import("../support/doe_native_runtime_helpers.zig");
const texture_formats = @import("../../contracts/model/model_texture_format_value_types.zig");
const resource_ops = @import("../../backend/dropin_resource_ops.zig");
const bridge = resource_ops.metal_bridge;

const doe_surface_supports_format = bridge.doe_surface_supports_format;

// BGRA8Unorm is the Metal-native swapchain format on Apple Silicon.
// All modern macOS display hardware uses BGRA byte order for CAMetalLayer.
// The WebGPU spec allows the adapter to pick; Metal's preferred format is bgra8unorm.
const PREFERRED_CANVAS_FORMAT: u32 = abi_texture.WGPUTextureFormat_BGRA8Unorm;

// ============================================================
// Adapter: getPreferredCanvasFormat
// ============================================================

// Returns the preferred canvas texture format for the adapter.
// Metal prefers BGRA8Unorm when the native bridge reports support.
// Vulkan returns the runtime's best-known surface-backed preference when a
// NativeVulkanRuntime is attached; otherwise it falls back to BGRA8Unorm,
// matching the repo-local Vulkan surface preference order.
pub export fn doeNativeAdapterGetPreferredCanvasFormat(raw: ?*anyopaque) callconv(.c) u32 {
    if (native_helpers.cast(native_types.DoeAdapter, raw)) |adapter| {
        if (adapter.backend == .vulkan) return texture_formats.WGPUTextureFormat_BGRA8Unorm;
    }
    if (native_helpers.cast(native_types.DoeDevice, raw)) |device| {
        if (device.backend == .vulkan) {
            if (comptime has_vulkan) {
                if (runtime_helpers.device_vk_runtime(device)) |rt| return rt.preferred_canvas_format();
            }
            return texture_formats.WGPUTextureFormat_BGRA8Unorm;
        }
    }
    if (builtin.os.tag == .macos) {
        if (doe_surface_supports_format(PREFERRED_CANVAS_FORMAT) != 0) return PREFERRED_CANVAS_FORMAT;
        const rgba8: u32 = abi_texture.WGPUTextureFormat_RGBA8Unorm;
        if (doe_surface_supports_format(rgba8) != 0) return rgba8;
    }
    return PREFERRED_CANVAS_FORMAT;
}

// ============================================================
// Device: DOM EventTarget stubs (addEventListener / removeEventListener)
// ============================================================

// addEventListener and removeEventListener are DOM EventTarget APIs.
// In a native non-browser runtime there is no DOM event source to register
// against, so these exports fail explicitly instead of silently accepting
// listener registration.

pub export fn doeNativeDeviceAddEventListener(
    dev_raw: ?*anyopaque,
    event_type_ptr: ?[*]const u8,
    event_type_len: usize,
    callback: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) void {
    _ = dev_raw;
    _ = event_type_ptr;
    _ = event_type_len;
    _ = callback;
    _ = userdata;
    std.log.err("doe: doeNativeDeviceAddEventListener: unsupported in native runtime (no DOM event source)", .{});
}

pub export fn doeNativeDeviceRemoveEventListener(
    dev_raw: ?*anyopaque,
    event_type_ptr: ?[*]const u8,
    event_type_len: usize,
    callback: ?*anyopaque,
    userdata: ?*anyopaque,
) callconv(.c) void {
    _ = dev_raw;
    _ = event_type_ptr;
    _ = event_type_len;
    _ = callback;
    _ = userdata;
    std.log.err("doe: doeNativeDeviceRemoveEventListener: unsupported in native runtime (no DOM event source)", .{});
}
