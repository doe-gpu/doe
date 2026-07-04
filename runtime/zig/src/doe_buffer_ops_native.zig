// doe_buffer_ops_native.zig — Buffer create, release, map, unmap, and mapped
// range operations. Sharded from doe_wgpu_native.zig.

const std = @import("std");
const builtin = @import("builtin");
const has_vulkan = (builtin.os.tag == .linux);
const abi_callback = @import("core/abi/wgpu_callback_descriptor_types.zig");
const abi_core = @import("core/abi/wgpu_core_base_types.zig");
const abi_pipeline = @import("core/abi/wgpu_pipeline_descriptor_types.zig");
const resource_ops = @import("backend/dropin_resource_ops.zig");
const native_shared = @import("doe_native_shared_types.zig");
const native_types = @import("doe_native_object_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const runtime_helpers = @import("doe_native_runtime_helpers.zig");
const vulkan_lifetime = @import("doe_vulkan_lifetime.zig");
const d3d12_constants = resource_ops.d3d12_constants;
const bridge = resource_ops.metal_bridge;
const vk_resources = if (has_vulkan) resource_ops.vk_resources else struct {};
const metal_bridge_buffer_contents = bridge.metal_bridge_buffer_contents;
const metal_bridge_device_new_buffer_private = bridge.metal_bridge_device_new_buffer_private;
const metal_bridge_device_new_buffer_shared = bridge.metal_bridge_device_new_buffer_shared;
const metal_bridge_release = bridge.metal_bridge_release;

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const object_should_destroy = native_helpers.object_should_destroy;
const label_store = native_helpers.label_store;
const DoeDevice = native_types.DoeDevice;
const DoeBuffer = native_types.DoeBuffer;
const NativeVulkanRuntime = native_shared.NativeVulkanRuntime;

const WGPU_MAP_ASYNC_STATUS_SUCCESS: u32 = 1;
const WGPU_MAP_ASYNC_STATUS_VALIDATION_ERROR: u32 = 4;
const D3D12_HEAP_TYPE_DEFAULT: c_int = 1;
const WHOLE_MAP_SIZE = std.math.maxInt(usize);
const WGPU_BUFFER_USAGE_INDIRECT: u64 = 0x0000000000000100;

fn resolve_buffer_map_range(buf: *const DoeBuffer, offset: usize, size: usize) ?usize {
    const offset_u64: u64 = @intCast(offset);
    if (offset_u64 > buf.size) return null;
    if (size == WHOLE_MAP_SIZE) return @intCast(buf.size - offset_u64);
    const size_u64: u64 = @intCast(size);
    if (size_u64 > buf.size - offset_u64) return null;
    return size;
}

fn buffer_map_range_ok(buf: *const DoeBuffer, offset: usize, size: usize) bool {
    return resolve_buffer_map_range(buf, offset, size) != null;
}

fn d3d12_upload_heap_usage_supported(usage: u64) bool {
    const disallowed = abi_core.WGPUBufferUsage_MapRead | abi_core.WGPUBufferUsage_CopyDst | abi_core.WGPUBufferUsage_Storage | abi_core.WGPUBufferUsage_QueryResolve;
    return (usage & disallowed) == 0;
}

fn d3d12_buffer_heap_type(desc: *const abi_pipeline.WGPUBufferDescriptor) ?c_int {
    const usage = desc.usage;
    const wants_map_read = (usage & abi_core.WGPUBufferUsage_MapRead) != 0;
    const wants_map_write = (usage & abi_core.WGPUBufferUsage_MapWrite) != 0;
    if (wants_map_read and wants_map_write) return null;
    if (wants_map_read) {
        if (desc.mappedAtCreation != 0) return null;
        return d3d12_constants.HEAP_TYPE_READBACK;
    }
    if (wants_map_write) return d3d12_constants.HEAP_TYPE_UPLOAD;
    if (desc.mappedAtCreation != 0) {
        if (!d3d12_upload_heap_usage_supported(usage)) return null;
        return d3d12_constants.HEAP_TYPE_UPLOAD;
    }
    return D3D12_HEAP_TYPE_DEFAULT;
}

fn metalPrivateBuffersEnabled() bool {
    const value = std.posix.getenv("DOE_METAL_PRIVATE_BUFFERS") orelse return false;
    if (value.len == 0) return false;
    const first = value[0];
    return first == '1' or first == 't' or first == 'T' or first == 'y' or first == 'Y';
}

pub fn metalBufferUsageEligibleForPrivateStorage(desc: *const abi_pipeline.WGPUBufferDescriptor) bool {
    if (desc.mappedAtCreation != 0) return false;
    const usage = desc.usage;
    const host_visible = abi_core.WGPUBufferUsage_MapRead | abi_core.WGPUBufferUsage_MapWrite;
    if ((usage & host_visible) != 0) return false;
    if ((usage & abi_core.WGPUBufferUsage_QueryResolve) != 0) return false;
    const gpu_visible =
        abi_core.WGPUBufferUsage_Index |
        abi_core.WGPUBufferUsage_Vertex |
        abi_core.WGPUBufferUsage_Uniform |
        abi_core.WGPUBufferUsage_Storage |
        WGPU_BUFFER_USAGE_INDIRECT;
    return (usage & gpu_visible) != 0;
}

pub fn metalBufferShouldUsePrivateStorage(desc: *const abi_pipeline.WGPUBufferDescriptor) bool {
    return metalPrivateBuffersEnabled() and metalBufferUsageEligibleForPrivateStorage(desc);
}

extern fn d3d12_bridge_device_create_buffer(device: ?*anyopaque, size: usize, heap_type: c_int) callconv(.c) ?*anyopaque;
extern fn d3d12_bridge_resource_map(resource: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn d3d12_bridge_resource_unmap(resource: ?*anyopaque) callconv(.c) void;
extern fn d3d12_bridge_release(obj: ?*anyopaque) callconv(.c) void;

pub export fn doeNativeDeviceCreateBuffer(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUBufferDescriptor) callconv(.c) ?*anyopaque {
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const d = desc orelse return null;
    const buf = make(DoeBuffer) orelse return null;
    buf.* = .{ .backend = dev.backend, .size = d.size, .usage = d.usage };
    if (comptime has_vulkan) {
        if (dev.backend == .vulkan) {
            const rt = runtime_helpers.device_vk_runtime(dev) orelse {
                alloc.destroy(buf);
                return null;
            };
            const id: u64 = @intFromPtr(buf);
            buf.vk_id = id;
            buf.vk_runtime_ref = @ptrCast(rt);
            const cb = vk_resources.create_compute_buffer(rt, d.size, false) catch {
                alloc.destroy(buf);
                return null;
            };
            rt.compute_buffers.put(rt.allocator, id, cb) catch {
                vk_resources.release_compute_buffer(rt, cb);
                alloc.destroy(buf);
                return null;
            };
            // Cache host-visible mapped pointer to skip HashMap lookup on writeBuffer.
            if (cb.mapped) |m| buf.vk_mapped_ptr = @ptrCast(m);
            if (d.mappedAtCreation != 0) buf.mapped = true;
            const result = toOpaque(buf);
            label_store.set(result, d.label.data, d.label.length);
            return result;
        }
    }
    if (dev.backend == .d3d12) {
        const rt = runtime_helpers.device_d3d12_runtime(dev) orelse {
            alloc.destroy(buf);
            return null;
        };
        const heap_type = d3d12_buffer_heap_type(d) orelse {
            alloc.destroy(buf);
            return null;
        };
        buf.mtl = d3d12_bridge_device_create_buffer(rt.device, @intCast(d.size), heap_type);
        if (buf.mtl == null) {
            alloc.destroy(buf);
            return null;
        }
        buf.d3d12_heap_type = heap_type;
        if (d.mappedAtCreation != 0) {
            buf.d3d12_mapped_ptr = d3d12_bridge_resource_map(buf.mtl) orelse {
                d3d12_bridge_release(buf.mtl);
                alloc.destroy(buf);
                return null;
            };
            buf.mapped = true;
        }
        const result = toOpaque(buf);
        label_store.set(result, d.label.data, d.label.length);
        return result;
    }
    const use_private_storage = metalBufferShouldUsePrivateStorage(d);
    buf.mtl = if (use_private_storage)
        metal_bridge_device_new_buffer_private(dev.mtl_device, @intCast(d.size))
    else
        metal_bridge_device_new_buffer_shared(dev.mtl_device, @intCast(d.size));
    if (buf.mtl == null) {
        alloc.destroy(buf);
        return null;
    }
    buf.metal_private_storage = use_private_storage;
    if (!use_private_storage) {
        buf.metal_mapped_ptr = metal_bridge_buffer_contents(buf.mtl);
    }
    if (d.mappedAtCreation != 0) buf.mapped = true;
    const result = toOpaque(buf);
    label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeDeviceCreateBufferFlat(dev_raw: ?*anyopaque, usage: u64, size: u64, mapped_at_creation: u32) callconv(.c) ?*anyopaque {
    var desc = abi_pipeline.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .usage = usage,
        .size = size,
        .mappedAtCreation = if (mapped_at_creation != 0) abi_core.WGPU_TRUE else abi_core.WGPU_FALSE,
    };
    return doeNativeDeviceCreateBuffer(dev_raw, &desc);
}

pub export fn doeNativeBufferRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeBuffer, raw)) |b| {
        if (!object_should_destroy(b)) return;
        label_store.remove(raw);
        if (comptime has_vulkan) {
            if (b.backend == .vulkan and b.vk_id != 0) {
                if (b.vk_runtime_ref) |rt_ptr| {
                    vulkan_lifetime.flushBeforeDestroy(rt_ptr);
                    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
                    if (rt.compute_buffers.fetchRemove(b.vk_id)) |entry| {
                        vk_resources.release_compute_buffer(rt, entry.value);
                    }
                }
                alloc.destroy(b);
                return;
            }
        }
        if (b.backend == .d3d12) {
            if (b.d3d12_mapped_ptr != null and b.mtl != null) {
                d3d12_bridge_resource_unmap(b.mtl);
                b.d3d12_mapped_ptr = null;
            }
            if (b.mtl) |handle| d3d12_bridge_release(handle);
            alloc.destroy(b);
            return;
        }
        b.metal_mapped_ptr = null;
        if (b.mtl) |m| metal_bridge_release(m);
        alloc.destroy(b);
    }
}

pub export fn doeNativeBufferUnmap(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeBuffer, raw)) |b| {
        if (b.backend == .d3d12 and b.d3d12_mapped_ptr != null and b.mtl != null) {
            d3d12_bridge_resource_unmap(b.mtl);
            b.d3d12_mapped_ptr = null;
        }
        b.mapped = false;
    }
}

const DOE_BUFFER_MAP_STATE_UNMAPPED: u32 = 1;
const DOE_BUFFER_MAP_STATE_MAPPED: u32 = 3;

pub export fn doeNativeBufferGetMapState(raw: ?*anyopaque) callconv(.c) u32 {
    const b = cast(DoeBuffer, raw) orelse return DOE_BUFFER_MAP_STATE_UNMAPPED;
    if (b.error_object) return DOE_BUFFER_MAP_STATE_UNMAPPED;
    return if (b.mapped) DOE_BUFFER_MAP_STATE_MAPPED else DOE_BUFFER_MAP_STATE_UNMAPPED;
}

pub export fn doeNativeBufferMapAsync(buf_raw: ?*anyopaque, mode: u64, offset: usize, size: usize, cb_info: abi_callback.WGPUBufferMapCallbackInfo) callconv(.c) abi_core.WGPUFuture {
    const b = cast(DoeBuffer, buf_raw) orelse {
        if (cb_info.callback) |callback| callback(WGPU_MAP_ASYNC_STATUS_VALIDATION_ERROR, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
        return .{ .id = 3 };
    };
    if (b.error_object) {
        if (cb_info.callback) |callback| callback(WGPU_MAP_ASYNC_STATUS_VALIDATION_ERROR, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
        return .{ .id = 3 };
    }
    if (!buffer_map_range_ok(b, offset, size)) {
        if (cb_info.callback) |callback| callback(WGPU_MAP_ASYNC_STATUS_VALIDATION_ERROR, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
        return .{ .id = 3 };
    }
    if (b.backend == .d3d12) {
        const wants_read = (mode & abi_core.WGPUMapMode_Read) != 0;
        const wants_write = (mode & abi_core.WGPUMapMode_Write) != 0;
        const expect_heap: c_int = if (wants_read and !wants_write) d3d12_constants.HEAP_TYPE_READBACK else if (wants_write and !wants_read) d3d12_constants.HEAP_TYPE_UPLOAD else 0;
        if (expect_heap == 0 or b.d3d12_heap_type != expect_heap or b.mtl == null) {
            if (cb_info.callback) |callback| callback(WGPU_MAP_ASYNC_STATUS_VALIDATION_ERROR, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
            return .{ .id = 3 };
        }
        if (b.d3d12_mapped_ptr == null) b.d3d12_mapped_ptr = d3d12_bridge_resource_map(b.mtl);
        if (b.d3d12_mapped_ptr == null) {
            if (cb_info.callback) |callback| callback(WGPU_MAP_ASYNC_STATUS_VALIDATION_ERROR, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
            return .{ .id = 3 };
        }
        b.mapped = true;
        if (cb_info.callback) |callback| callback(WGPU_MAP_ASYNC_STATUS_SUCCESS, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
        return .{ .id = 3 };
    }
    if (comptime has_vulkan) {
        if (b.backend == .vulkan and (mode & abi_core.WGPUMapMode_Read) != 0) {
            if (b.vk_runtime_ref) |rt_ptr| {
                const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
                _ = rt.flush_queue() catch {
                    if (cb_info.callback) |callback| callback(WGPU_MAP_ASYNC_STATUS_VALIDATION_ERROR, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
                    return .{ .id = 3 };
                };
            }
        }
    }
    b.mapped = true;
    if (cb_info.callback) |callback| callback(WGPU_MAP_ASYNC_STATUS_SUCCESS, .{ .data = null, .length = 0 }, cb_info.userdata1, cb_info.userdata2);
    return .{ .id = 3 };
}

pub export fn doeNativeBufferGetConstMappedRange(buf_raw: ?*anyopaque, offset: usize, size: usize) callconv(.c) ?*anyopaque {
    const buf = cast(DoeBuffer, buf_raw) orelse return null;
    if (buf.error_object) return null;
    if (!buf.mapped) return null;
    const range_size = resolve_buffer_map_range(buf, offset, size) orelse return null;
    _ = range_size;
    if (comptime has_vulkan) {
        if (buf.backend == .vulkan) {
            // Fast path: use cached mapped pointer to avoid HashMap lookup.
            if (buf.vk_mapped_ptr) |base| return @ptrCast(base + offset);
            // Fallback: HashMap lookup for buffers without a cached pointer.
            if (buf.vk_id != 0) {
                if (buf.vk_runtime_ref) |rt_ptr| {
                    const rt: *NativeVulkanRuntime = @ptrCast(@alignCast(rt_ptr));
                    const cb = rt.compute_buffers.get(buf.vk_id) orelse return null;
                    const base: [*]u8 = @ptrCast(cb.mapped orelse return null);
                    return @ptrCast(base + offset);
                }
            }
            return null;
        }
    }
    if (buf.backend == .d3d12) {
        const mapped = buf.d3d12_mapped_ptr orelse return null;
        const base: [*]u8 = @ptrCast(mapped);
        return @ptrCast(base + offset);
    }
    const contents = buf.metal_mapped_ptr orelse metal_bridge_buffer_contents(buf.mtl) orelse return null;
    return @ptrCast(contents + offset);
}

pub export fn doeNativeBufferGetMappedRange(buf_raw: ?*anyopaque, offset: usize, size: usize) callconv(.c) ?*anyopaque {
    return doeNativeBufferGetConstMappedRange(buf_raw, offset, size);
}

test "resolve_buffer_map_range accepts whole-map sentinel" {
    const buf = DoeBuffer{ .size = 4096 };
    try std.testing.expectEqual(@as(?usize, 4096), resolve_buffer_map_range(&buf, 0, WHOLE_MAP_SIZE));
    try std.testing.expectEqual(@as(?usize, 3840), resolve_buffer_map_range(&buf, 256, WHOLE_MAP_SIZE));
}

test "resolve_buffer_map_range rejects overflow past buffer size" {
    const buf = DoeBuffer{ .size = 1024 };
    try std.testing.expectEqual(@as(?usize, null), resolve_buffer_map_range(&buf, 2048, WHOLE_MAP_SIZE));
    try std.testing.expectEqual(@as(?usize, null), resolve_buffer_map_range(&buf, 128, 1024));
}
