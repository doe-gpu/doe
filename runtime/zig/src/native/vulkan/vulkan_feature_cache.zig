const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.doe_vulkan_feature_cache);
const has_vulkan = (builtin.os.tag == .linux);
const backend_capabilities = @import("../../backend/dropin_capabilities.zig");
const vk_feature_caps = if (has_vulkan) backend_capabilities.vk_feature_caps else struct {
    pub const VulkanFeatureCaps = struct {};
};
const vk_device_caps = if (has_vulkan) backend_capabilities.vk_device_caps else struct {
    pub const VulkanDeviceCaps = struct {};
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const alloc = gpa.allocator();

var adapter_caps: std.AutoHashMapUnmanaged(usize, vk_feature_caps.VulkanFeatureCaps) = .{};
var device_caps: std.AutoHashMapUnmanaged(usize, vk_feature_caps.VulkanFeatureCaps) = .{};

// Hardware-queried limits and feature booleans, cached per adapter/device handle.
var adapter_device_caps: std.AutoHashMapUnmanaged(usize, vk_device_caps.VulkanDeviceCaps) = .{};
var device_device_caps: std.AutoHashMapUnmanaged(usize, vk_device_caps.VulkanDeviceCaps) = .{};

fn cache_key(handle: ?*anyopaque) ?usize {
    return if (handle) |ptr| @intFromPtr(ptr) else null;
}

pub fn set_adapter(handle: ?*anyopaque, caps: vk_feature_caps.VulkanFeatureCaps) void {
    const key = cache_key(handle) orelse return;
    adapter_caps.put(alloc, key, caps) catch |err| {
        log.warn("set_adapter: {s}", .{@errorName(err)});
    };
}

pub fn get_adapter(handle: ?*anyopaque) ?vk_feature_caps.VulkanFeatureCaps {
    const key = cache_key(handle) orelse return null;
    return adapter_caps.get(key);
}

pub fn remove_adapter(handle: ?*anyopaque) void {
    const key = cache_key(handle) orelse return;
    _ = adapter_caps.remove(key);
    _ = adapter_device_caps.remove(key);
}

pub fn set_device(handle: ?*anyopaque, caps: vk_feature_caps.VulkanFeatureCaps) void {
    const key = cache_key(handle) orelse return;
    device_caps.put(alloc, key, caps) catch |err| {
        log.warn("set_device: {s}", .{@errorName(err)});
    };
}

pub fn get_device(handle: ?*anyopaque) ?vk_feature_caps.VulkanFeatureCaps {
    const key = cache_key(handle) orelse return null;
    return device_caps.get(key);
}

pub fn remove_device(handle: ?*anyopaque) void {
    const key = cache_key(handle) orelse return;
    _ = device_caps.remove(key);
    _ = device_device_caps.remove(key);
}

// --- Vulkan device caps (limits + hardware features) ---

pub fn set_adapter_device_caps(handle: ?*anyopaque, caps: vk_device_caps.VulkanDeviceCaps) void {
    const key = cache_key(handle) orelse return;
    adapter_device_caps.put(alloc, key, caps) catch |err| {
        log.warn("set_adapter_device_caps: {s}", .{@errorName(err)});
    };
}

pub fn get_adapter_device_caps(handle: ?*anyopaque) ?vk_device_caps.VulkanDeviceCaps {
    const key = cache_key(handle) orelse return null;
    return adapter_device_caps.get(key);
}

pub fn set_device_device_caps(handle: ?*anyopaque, caps: vk_device_caps.VulkanDeviceCaps) void {
    const key = cache_key(handle) orelse return;
    device_device_caps.put(alloc, key, caps) catch |err| {
        log.warn("set_device_device_caps: {s}", .{@errorName(err)});
    };
}

pub fn get_device_device_caps(handle: ?*anyopaque) ?vk_device_caps.VulkanDeviceCaps {
    const key = cache_key(handle) orelse return null;
    return device_device_caps.get(key);
}
