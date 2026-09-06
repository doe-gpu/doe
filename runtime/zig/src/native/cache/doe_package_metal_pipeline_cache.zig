//! Device-owned Metal archives. The registry supports the legacy process flush
//! boundary; it neither shares archives nor owns devices.
const std = @import("std");
const builtin = @import("builtin");
const metal_package_pipeline_cache = @import("../../backend/metal_package_pipeline_cache.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");

const DoeDevice = native_types.DoeDevice;
const alloc = native_helpers.alloc;
const Entry = struct {
    cache: *metal_package_pipeline_cache.MetalPipelineCache,
    mutex: std.Thread.Mutex = .{},
    next: ?*Entry = null,
};
var registry_mutex = std.Thread.Mutex{};
var registry: ?*Entry = null;

fn get(dev: *DoeDevice) ?*Entry {
    if (builtin.os.tag != .macos or dev.backend != .metal) return null;
    const mtl_device = dev.mtl_device orelse return null;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (dev.metal_pipeline_cache) |raw| return @ptrCast(@alignCast(raw));
    const entry = alloc.create(Entry) catch return null;
    const cache = metal_package_pipeline_cache.init(alloc, mtl_device, "") catch {
        alloc.destroy(entry);
        return null;
    };
    entry.* = .{ .cache = cache, .next = registry };
    registry = entry;
    dev.metal_pipeline_cache = @ptrCast(entry);
    return entry;
}

/// The caller retains its device through compilation; only this archive is locked.
pub fn compileCompute(dev: *DoeDevice, function: ?*anyopaque) ?*anyopaque {
    const entry = get(dev) orelse return null;
    entry.mutex.lock();
    defer entry.mutex.unlock();
    return entry.cache.compile_or_serve_compute(function);
}

pub fn deinitForDevice(dev: *DoeDevice) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const raw = dev.metal_pipeline_cache orelse return;
    const entry: *Entry = @ptrCast(@alignCast(raw));
    var link = &registry;
    while (link.*) |current| {
        if (current == entry) {
            link.* = entry.next;
            break;
        }
        link = &current.next;
    }
    dev.metal_pipeline_cache = null;
    entry.mutex.lock();
    entry.cache.deinit();
    entry.mutex.unlock();
    alloc.destroy(entry);
}

pub fn flush() void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    var next = registry;
    while (next) |entry| {
        entry.mutex.lock();
        entry.cache.flush_archive();
        entry.mutex.unlock();
        next = entry.next;
    }
}

pub export fn doeNativePackagePipelineCacheFlush() callconv(.c) void {
    flush();
}
