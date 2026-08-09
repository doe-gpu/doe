// multi_adapter.zig — Adapter enumeration, selection, and info for the Doe runtime.
//
// On macOS, MTLCopyAllDevices() returns every available GPU.  This module wraps that
// list as DoeAdapterInfo records and implements the selection logic required by
// wgpuInstanceRequestAdapter (powerPreference, forceFallbackAdapter).
//
// Cross-device buffer transfer and device-lost notification are also handled here.

const builtin = @import("builtin");
const std = @import("std");
const process_roots = @import("../process_roots.zig");

// ============================================================
// Constants

const MAGIC_ADAPTER_INFO: u32 = 0xD0E1_AD70;
const MAGIC_ADAPTER_LIST: u32 = 0xD0E1_AD71;
const MAX_ADAPTERS: usize = 16;
const MAX_DEVICE_NAME_BYTES: usize = 256;
const DEVICE_LOST_REASON_DESTROYED: u32 = 1;

// WebGPU power preference constants — match wgpu.h values.
const WGPU_POWER_PREF_UNDEFINED: u32 = 0;
const WGPU_POWER_PREF_LOW_POWER: u32 = 1;
const WGPU_POWER_PREF_HIGH_PERFORMANCE: u32 = 2;

// ============================================================
// Adapter type classification

pub const AdapterType = enum(u32) {
    discrete_gpu = 0,
    integrated_gpu = 1,
    cpu = 2, // software renderer
    unknown = 3,
};

pub const BackendType = enum(u32) {
    metal = 1,
    vulkan = 2,
    d3d12 = 3,
    null_backend = 0,
};

// ============================================================
// Adapter info record (runtime-owned, not tied to a live MTLDevice)

pub const DoeAdapterInfo = extern struct {
    magic: u32 = MAGIC_ADAPTER_INFO,
    // Pointer to MTLDevice (retained +1, freed on DoeAdapterInfo release).
    mtl_device: ?*anyopaque = null,
    // Adapter type: discrete, integrated, cpu, unknown.
    adapter_type: AdapterType = .unknown,
    backend_type: BackendType = .metal,
    // Stable GPU registry ID from MTLDevice.registryID.
    registry_id: u64 = 0,
    // isLowPower, isRemovable from MTLDevice.
    is_low_power: bool = false,
    is_removable: bool = false,
    // Null-terminated device name (from MTLDevice.name, UTF-8).
    name: [MAX_DEVICE_NAME_BYTES]u8 = [_]u8{0} ** MAX_DEVICE_NAME_BYTES,
    name_len: u32 = 0,
    // Vendor string ("apple", "amd", "nvidia", "intel", "unknown").
    vendor: [64]u8 = [_]u8{0} ** 64,
    vendor_len: u32 = 0,
};

// ============================================================
// Adapter list (result of enumerating all devices)

pub const DoeAdapterList = struct {
    magic: u32 = MAGIC_ADAPTER_LIST,
    allocator: std.mem.Allocator,
    // Owned DoeAdapterInfo records.  Each mtl_device is +1 retained.
    items: []DoeAdapterInfo,
    count: usize,

    pub fn deinit(self: *DoeAdapterList) void {
        for (self.items[0..self.count]) |*info| {
            if (info.mtl_device) |d| metal_bridge_release(d);
        }
        self.allocator.free(self.items);
        self.allocator.destroy(self);
    }
};

// ============================================================
// Metal bridge declarations — implemented by the ObjC metal_bridge.m unit.

extern fn metal_bridge_release(obj: ?*anyopaque) callconv(.c) void;

// Enumerate all MTLDevices.  Returns an array of retained handles and fills `out_count`.
// Returns null on non-macOS platforms.
extern fn metal_bridge_enumerate_devices(
    out_devices: ?[*]?*anyopaque,
    max_count: u32,
    out_count: *u32,
) callconv(.c) void;

// Query device properties (fills the fields below via output parameters).
extern fn metal_bridge_device_registry_id(device: ?*anyopaque) callconv(.c) u64;
extern fn metal_bridge_device_is_low_power(device: ?*anyopaque) callconv(.c) u32;
extern fn metal_bridge_device_is_removable(device: ?*anyopaque) callconv(.c) u32;
// Writes the device name as UTF-8 into `buf` (null-terminated, truncated to `cap`).
extern fn metal_bridge_device_name(device: ?*anyopaque, buf: [*]u8, cap: usize) callconv(.c) void;

// ============================================================
// Enumeration

pub fn enumerate_all(allocator: std.mem.Allocator) !*DoeAdapterList {
    const list = try allocator.create(DoeAdapterList);
    errdefer allocator.destroy(list);

    const items = try allocator.alloc(DoeAdapterInfo, MAX_ADAPTERS);
    errdefer allocator.free(items);

    list.* = .{
        .allocator = allocator,
        .items = items,
        .count = 0,
    };

    if (builtin.os.tag != .macos) {
        // On non-macOS there are no Metal devices; return empty list.
        return list;
    }

    var raw_devices: [MAX_ADAPTERS]?*anyopaque = [_]?*anyopaque{null} ** MAX_ADAPTERS;
    var found: u32 = 0;
    metal_bridge_enumerate_devices(@ptrCast(&raw_devices), MAX_ADAPTERS, &found);

    const n = @min(@as(usize, found), MAX_ADAPTERS);
    for (raw_devices[0..n], 0..) |dev, i| {
        var info = DoeAdapterInfo{};
        info.mtl_device = dev;
        info.registry_id = metal_bridge_device_registry_id(dev);
        info.is_low_power = metal_bridge_device_is_low_power(dev) != 0;
        info.is_removable = metal_bridge_device_is_removable(dev) != 0;

        // Fill name.
        metal_bridge_device_name(dev, &info.name, MAX_DEVICE_NAME_BYTES);
        info.name_len = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(&info.name))));

        // Classify adapter type.
        info.adapter_type = classify_adapter_type(info.is_low_power, info.is_removable);

        // Derive vendor string from device name (best-effort heuristic).
        fill_vendor_from_name(&info);

        info.backend_type = .metal;
        items[i] = info;
        list.count += 1;
    }

    return list;
}

fn classify_adapter_type(is_low_power: bool, is_removable: bool) AdapterType {
    _ = is_removable;
    // Metal exposes no explicit "is discrete" flag; low-power implies integrated.
    if (is_low_power) return .integrated_gpu;
    return .discrete_gpu;
}

fn fill_vendor_from_name(info: *DoeAdapterInfo) void {
    const name_slice = info.name[0..info.name_len];
    const known_vendors = [_]struct { needle: []const u8, vendor: []const u8 }{
        .{ .needle = "Apple", .vendor = "apple" },
        .{ .needle = "AMD", .vendor = "amd" },
        .{ .needle = "NVIDIA", .vendor = "nvidia" },
        .{ .needle = "Intel", .vendor = "intel" },
    };
    for (known_vendors) |kv| {
        if (std.mem.containsAtLeast(u8, name_slice, 1, kv.needle)) {
            const n = @min(kv.vendor.len, info.vendor.len - 1);
            std.mem.copyForwards(u8, info.vendor[0..n], kv.vendor[0..n]);
            info.vendor[n] = 0;
            info.vendor_len = @intCast(n);
            return;
        }
    }
    const unknown = "unknown";
    std.mem.copyForwards(u8, info.vendor[0..unknown.len], unknown);
    info.vendor[unknown.len] = 0;
    info.vendor_len = @intCast(unknown.len);
}

// ============================================================
// Selection

pub const AdapterOptions = struct {
    power_preference: u32 = WGPU_POWER_PREF_UNDEFINED,
    force_fallback: bool = false,
};

// Return index into list.items[0..list.count] of the best adapter, or null if empty.
pub fn select_adapter(list: *const DoeAdapterList, opts: AdapterOptions) ?usize {
    if (list.count == 0) return null;

    if (opts.force_fallback) {
        // Prefer CPU/software adapters for fallback.
        for (list.items[0..list.count], 0..) |*info, i| {
            if (info.adapter_type == .cpu) return i;
        }
        // No CPU adapter available; return first.
        return 0;
    }

    // Score each adapter: higher is better.
    var best_idx: usize = 0;
    var best_score: i32 = -1;

    for (list.items[0..list.count], 0..) |*info, i| {
        var score: i32 = 0;
        switch (info.adapter_type) {
            .discrete_gpu => score += 100,
            .integrated_gpu => score += 50,
            .cpu => score -= 50,
            .unknown => {},
        }
        // Removable GPUs (eGPUs) get a slight penalty to avoid selecting them by default.
        if (info.is_removable) score -= 10;

        // Apply power preference.
        switch (opts.power_preference) {
            WGPU_POWER_PREF_HIGH_PERFORMANCE => {
                if (!info.is_low_power) score += 20;
            },
            WGPU_POWER_PREF_LOW_POWER => {
                if (info.is_low_power) score += 20;
            },
            else => {},
        }

        if (score > best_score) {
            best_score = score;
            best_idx = i;
        }
    }

    return best_idx;
}

// ============================================================
// C ABI exports

pub export fn doeNativeInstanceEnumerateAdapters(
    _inst: ?*anyopaque,
    out_list: *?*anyopaque,
) callconv(.c) u32 {
    _ = _inst;
    const list = enumerate_all(process_roots.adapterAllocator()) catch {
        out_list.* = null;
        return 0;
    };
    out_list.* = @ptrCast(list);
    return @intCast(list.count);
}

pub export fn doeNativeAdapterListGetCount(raw: ?*anyopaque) callconv(.c) u32 {
    const list = adapter_list_from_opaque(raw) orelse return 0;
    return @intCast(list.count);
}

// Fill the caller-provided DoeAdapterInfo struct at index idx.
// Returns 1 on success, 0 if index is out of range.
pub export fn doeNativeAdapterListGetInfo(
    raw: ?*anyopaque,
    idx: u32,
    out: ?*DoeAdapterInfo,
) callconv(.c) u32 {
    const list = adapter_list_from_opaque(raw) orelse return 0;
    const out_info = out orelse return 0;
    if (idx >= list.count) return 0;
    out_info.* = list.items[idx];
    // mtl_device in the copy is NOT retained — caller must not release it.
    out_info.mtl_device = null;
    return 1;
}

// Acquire an MTLDevice handle (+1 retained) for adapter at idx.
// Caller must call metal_bridge_release() when done.
pub export fn doeNativeAdapterListRetainDevice(
    raw: ?*anyopaque,
    idx: u32,
) callconv(.c) ?*anyopaque {
    const list = adapter_list_from_opaque(raw) orelse return null;
    if (idx >= list.count) return null;
    const dev = list.items[idx].mtl_device orelse return null;
    // Retain once more for the caller.
    metal_bridge_retain_device(dev);
    return dev;
}

pub export fn doeNativeAdapterListRelease(raw: ?*anyopaque) callconv(.c) void {
    if (adapter_list_from_opaque(raw)) |list| list.deinit();
}

// Returns the adapter index that best matches `power_preference`.
// 0 = undefined, 1 = low_power, 2 = high_performance.
pub export fn doeNativeInstanceSelectAdapter(
    list_raw: ?*anyopaque,
    power_preference: u32,
    force_fallback: u32,
) callconv(.c) u32 {
    const list = adapter_list_from_opaque(list_raw) orelse return 0;
    const opts = AdapterOptions{
        .power_preference = power_preference,
        .force_fallback = force_fallback != 0,
    };
    return @intCast(select_adapter(list, opts) orelse 0);
}

// Get adapter info as a DoeAdapterInfo struct for a single DoeAdapter handle.
// Named *Struct to avoid symbol collision with the string-based doeNativeAdapterGetInfo
// in doe_adapter_info_native.zig (used by the N-API layer).
pub export fn doeNativeAdapterGetInfoStruct(
    adapter_raw: ?*anyopaque,
    out: ?*DoeAdapterInfo,
) callconv(.c) u32 {
    const out_info = out orelse return 0;
    const dev = device_from_adapter_opaque(adapter_raw) orelse return 0;

    var info = DoeAdapterInfo{};
    info.mtl_device = null; // do not expose handle directly
    info.registry_id = metal_bridge_device_registry_id(dev);
    info.is_low_power = metal_bridge_device_is_low_power(dev) != 0;
    info.is_removable = metal_bridge_device_is_removable(dev) != 0;
    info.adapter_type = classify_adapter_type(info.is_low_power, info.is_removable);
    info.backend_type = .metal;
    metal_bridge_device_name(dev, &info.name, MAX_DEVICE_NAME_BYTES);
    info.name_len = @intCast(std.mem.len(@as([*:0]const u8, @ptrCast(&info.name))));
    fill_vendor_from_name(&info);

    out_info.* = info;
    return 1;
}

// ============================================================
// Device lost callback support

pub const DeviceLostCallback = *const fn (reason: u32, message_ptr: ?[*]const u8, message_len: usize, userdata: ?*anyopaque) callconv(.c) void;

pub export fn doeNativeDeviceRegisterLostCallback(
    _dev: ?*anyopaque,
    callback: ?DeviceLostCallback,
    userdata: ?*anyopaque,
) callconv(.c) void {
    // Store callback per device.  In practice Doe devices are torn down explicitly;
    // we fire the callback immediately with reason=destroyed on doeNativeDeviceRelease.
    // For eGPU hot-unplug, doeNativeDeviceNotifyLost is called from the ObjC removal
    // notification observer registered in metal_multi_device.m.
    const allocator = process_roots.adapterAllocator();
    const reg = allocator.create(DeviceLostReg) catch return;
    reg.* = .{
        .dev = _dev,
        .callback = callback,
        .userdata = userdata,
    };
    device_lost_registry_insert(reg);
}

pub export fn doeNativeDeviceNotifyLost(
    dev: ?*anyopaque,
    reason: u32,
    message_ptr: ?[*]const u8,
    message_len: usize,
) callconv(.c) void {
    device_lost_fire_and_remove(dev, reason, message_ptr, message_len);
}

// ============================================================
// Device-lost registry (simple singly-linked list, not performance-sensitive)

const DeviceLostReg = struct {
    dev: ?*anyopaque,
    callback: ?DeviceLostCallback,
    userdata: ?*anyopaque,
    next: ?*DeviceLostReg = null,
};

var lost_reg_head: ?*DeviceLostReg = null;

fn device_lost_registry_insert(reg: *DeviceLostReg) void {
    reg.next = lost_reg_head;
    lost_reg_head = reg;
}

fn device_lost_fire_and_remove(dev: ?*anyopaque, reason: u32, msg_ptr: ?[*]const u8, msg_len: usize) void {
    var prev: ?*DeviceLostReg = null;
    var cur = lost_reg_head;
    while (cur) |node| {
        if (node.dev == dev) {
            if (node.callback) |cb| cb(reason, msg_ptr, msg_len, node.userdata);
            // Remove from list.
            if (prev) |p| {
                p.next = node.next;
            } else {
                lost_reg_head = node.next;
            }
            process_roots.adapterAllocator().destroy(node);
            return;
        }
        prev = node;
        cur = node.next;
    }
}

// Called by doeNativeDeviceRelease to synthesise a "destroyed" lost event.
pub fn notify_device_released(dev: ?*anyopaque) void {
    const msg = "device_released";
    device_lost_fire_and_remove(dev, DEVICE_LOST_REASON_DESTROYED, msg.ptr, msg.len);
}

// ============================================================
// Metal bridge helpers needed by this module but implemented in ObjC

// Increments the Metal retain count of a MTLDevice (used when handing device out).
extern fn metal_bridge_retain_device(device: ?*anyopaque) callconv(.c) void;

// ============================================================
// Internal downcast helpers

// DoeAdapter is defined in doe_wgpu_native.zig.  We access the mtl_device field via
// the known layout (magic at offset 0, mtl_device at offset 4).
fn device_from_adapter_opaque(raw: ?*anyopaque) ?*anyopaque {
    const p = raw orelse return null;
    // The DoeAdapter struct starts with magic (u32) then mtl_device (*anyopaque).
    const MAGIC_ADAPTER: u32 = 0xD0E1_0002;
    const magic_ptr: *u32 = @ptrCast(@alignCast(p));
    if (magic_ptr.* != MAGIC_ADAPTER) return null;
    // mtl_device is at byte offset 4 (u32 magic, then pointer aligned to 8 on 64-bit).
    // Layout: magic: u32 (4 bytes) + pad (4 bytes) + mtl_device: *anyopaque (8 bytes)
    const dev_ptr: **anyopaque = @ptrFromInt(@intFromPtr(p) + @offsetOf(DoeAdapterLayout, "mtl_device"));
    return dev_ptr.*;
}

// Matches the layout declared in doe_wgpu_native.zig.
const DoeAdapterLayout = extern struct {
    magic: u32,
    mtl_device: ?*anyopaque,
};

fn adapter_list_from_opaque(raw: ?*anyopaque) ?*DoeAdapterList {
    const p = raw orelse return null;
    const list: *DoeAdapterList = @ptrCast(@alignCast(p));
    if (list.magic != MAGIC_ADAPTER_LIST) return null;
    return list;
}
