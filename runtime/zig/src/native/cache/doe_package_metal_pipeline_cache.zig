const std = @import("std");
const builtin = @import("builtin");
const metal_package_pipeline_cache = @import("../../backend/metal_package_pipeline_cache.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");

const DoeDevice = native_types.DoeDevice;
const alloc = native_helpers.alloc;

var cache_mutex = std.Thread.Mutex{};
var active_cache: ?*metal_package_pipeline_cache.MetalPipelineCache = null;
var active_device: ?*anyopaque = null;

pub fn get(dev: *DoeDevice) ?*metal_package_pipeline_cache.MetalPipelineCache {
    if (builtin.os.tag != .macos) return null;
    if (dev.backend != .metal) return null;
    const mtl_device = dev.mtl_device orelse return null;

    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (active_cache) |cache| {
        if (active_device == mtl_device) return cache;
        return null;
    }

    const cache = metal_package_pipeline_cache.init(alloc, mtl_device, "") catch return null;
    active_cache = cache;
    active_device = mtl_device;
    return cache;
}

pub fn deinitForDevice(dev: *DoeDevice) void {
    if (builtin.os.tag != .macos) return;
    const mtl_device = dev.mtl_device orelse return;

    cache_mutex.lock();
    defer cache_mutex.unlock();

    const cache = active_cache orelse return;
    if (active_device != mtl_device) return;
    cache.deinit();
    active_cache = null;
    active_device = null;
}

pub fn flush() void {
    if (builtin.os.tag != .macos) return;

    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (active_cache) |cache| cache.flush_archive();
}

pub export fn doeNativePackagePipelineCacheFlush() callconv(.c) void {
    flush();
}
