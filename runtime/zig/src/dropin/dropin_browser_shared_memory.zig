const std = @import("std");
const builtin = @import("builtin");

const abi_callback = @import("../core/abi/wgpu_callback_descriptor_types.zig");
const abi_core = @import("../core/abi/wgpu_core_base_types.zig");
const abi_pipeline = @import("../core/abi/wgpu_pipeline_descriptor_types.zig");
const abi_texture = @import("../core/abi/wgpu_texture_base_types.zig");
const external_texture_ops = @import("../backend/dropin_external_texture.zig");
const native = @import("../native/mod.zig");
const texture_sampler = @import("../native/resource/doe_texture_sampler_native.zig");
const queue_flush_breakdown = @import("../native/queue/doe_queue_flush_breakdown.zig");

pub const WGPUSharedBufferMemory = ?*anyopaque;
pub const WGPUSharedFence = ?*anyopaque;
pub const WGPUSharedTextureMemory = ?*anyopaque;
const WGPUStatus_Error: abi_core.WGPUStatus = 2;
const MAGIC_SHARED_TEXTURE_MEMORY: u32 = 0xD0E1_0020;
const MAGIC_SHARED_FENCE: u32 = 0xD0E1_0021;
const STYPE_SHARED_TEXTURE_MEMORY_IOSURFACE_DESCRIPTOR: abi_core.WGPUSType = 0x0005_0023;
const STYPE_SHARED_FENCE_MTL_SHARED_EVENT_DESCRIPTOR: abi_core.WGPUSType = 0x0005_0032;
const STYPE_SHARED_FENCE_MTL_SHARED_EVENT_EXPORT_INFO: abi_core.WGPUSType = 0x0005_0033;
const SHARED_FENCE_TYPE_MTL_SHARED_EVENT: u32 = 5;
const SHARED_FENCE_SIGNAL_VALUE: u64 = 1;
pub const WGPUSharedBufferMemoryDescriptor = extern struct {
    nextInChain: ?*anyopaque,
    label: abi_core.WGPUStringView,
};

pub const WGPUSharedBufferMemoryBeginAccessDescriptor = extern struct {
    nextInChain: ?*anyopaque,
    fenceCount: usize,
    fences: ?[*]const WGPUSharedFence,
    signaledValues: ?[*]const u64,
};

pub const WGPUSharedBufferMemoryEndAccessState = extern struct {
    nextInChain: ?*anyopaque,
    initialized: abi_core.WGPUBool,
    fenceCount: usize,
    fences: ?[*]const WGPUSharedFence,
    signaledValues: ?[*]const u64,
};

pub const WGPUSharedBufferMemoryProperties = extern struct {
    nextInChain: ?*anyopaque,
    size: u64,
    usage: u64,
};

pub const WGPUSharedFenceDescriptor = extern struct {
    nextInChain: ?*anyopaque,
    label: abi_core.WGPUStringView,
};

pub const WGPUSharedFenceExportInfo = extern struct {
    nextInChain: ?*anyopaque,
    type: u32,
};

const WGPUSharedFenceMTLSharedEventDescriptor = extern struct {
    chain: abi_callback.WGPUChainedStruct,
    sharedEvent: ?*anyopaque,
};

const WGPUSharedFenceMTLSharedEventExportInfo = extern struct {
    chain: abi_callback.WGPUChainedStruct,
    sharedEvent: ?*anyopaque,
};

pub const WGPUSharedTextureMemoryDescriptor = extern struct {
    nextInChain: ?*anyopaque,
    label: abi_core.WGPUStringView,
};

pub const WGPUSharedTextureMemoryBeginAccessDescriptor = extern struct {
    nextInChain: ?*anyopaque,
    concurrentRead: abi_core.WGPUBool,
    initialized: abi_core.WGPUBool,
    fenceCount: usize,
    fences: ?[*]const WGPUSharedFence,
    signaledValues: ?[*]const u64,
};

pub const WGPUSharedTextureMemoryEndAccessState = extern struct {
    nextInChain: ?*anyopaque,
    initialized: abi_core.WGPUBool,
    fenceCount: usize,
    fences: ?[*]const WGPUSharedFence,
    signaledValues: ?[*]const u64,
};

pub const WGPUExtent3D = extern struct {
    width: u32,
    height: u32,
    depthOrArrayLayers: u32,
};

pub const WGPUSharedTextureMemoryProperties = extern struct {
    nextInChain: ?*anyopaque,
    usage: u64,
    size: WGPUExtent3D,
    format: u32,
};

const WGPUSharedTextureMemoryIOSurfaceDescriptor = extern struct {
    chain: abi_callback.WGPUChainedStruct,
    ioSurface: ?*anyopaque,
    allowStorageBinding: abi_core.WGPUBool,
};

const DoeSharedTextureMemory = struct {
    pub const TYPE_MAGIC = MAGIC_SHARED_TEXTURE_MEMORY;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    backend: native.BackendKind = .metal,
    queue: ?*native.DoeQueue = null,
    iosurface: ?*anyopaque = null,
    width: u32 = 0,
    height: u32 = 0,
    usage: u64 = abi_texture.WGPUTextureUsage_TextureBinding |
        abi_texture.WGPUTextureUsage_RenderAttachment |
        abi_texture.WGPUTextureUsage_CopySrc |
        abi_texture.WGPUTextureUsage_CopyDst,
    format: u32 = abi_texture.WGPUTextureFormat_Undefined,
    access_start_event_counter: u64 = 0,
    in_access: bool = false,
};

const DoeSharedFence = struct {
    pub const TYPE_MAGIC = MAGIC_SHARED_FENCE;
    magic: u32 = TYPE_MAGIC,
    ref_count: u32 = 1,
    shared_event: ?*anyopaque = null,
};

const CompletionFence = struct {
    fence: WGPUSharedFence,
    signaled_value: u64,
};

extern fn CFRetain(cf: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn CFRelease(cf: ?*anyopaque) callconv(.c) void;
extern fn metal_bridge_device_new_shared_event(device: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn metal_bridge_retain(object: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn metal_bridge_create_command_buffer(queue: ?*anyopaque) callconv(.c) ?*anyopaque;
extern fn metal_bridge_command_buffer_encode_signal_event(command_buffer: ?*anyopaque, event: ?*anyopaque, value: u64) callconv(.c) void;
extern fn metal_bridge_command_buffer_commit(command_buffer: ?*anyopaque) callconv(.c) void;
extern fn metal_bridge_shared_event_wait(event: ?*anyopaque, value: u64) callconv(.c) void;
extern fn metal_bridge_release(object: ?*anyopaque) callconv(.c) void;

fn logUnsupported(comptime symbol_name: []const u8) void {
    std.log.err("doe: {s} is unsupported until the Chromium shared-image bridge imports native handles through Doe", .{symbol_name});
}

fn labelOwnedObject(raw: ?*anyopaque, label: abi_core.WGPUStringView) void {
    native.label_store.set(raw, label.data, label.length);
}

fn sharedTextureMemoryCast(raw: WGPUSharedTextureMemory) ?*DoeSharedTextureMemory {
    return native.cast(DoeSharedTextureMemory, raw);
}

fn sharedFenceCast(raw: WGPUSharedFence) ?*DoeSharedFence {
    return native.cast(DoeSharedFence, raw);
}

fn findIOSurfaceDescriptor(
    descriptor: *const WGPUSharedTextureMemoryDescriptor,
) ?*const WGPUSharedTextureMemoryIOSurfaceDescriptor {
    var chain_raw = descriptor.nextInChain;
    while (chain_raw) |raw| {
        const chain: *const abi_callback.WGPUChainedStruct = @ptrCast(@alignCast(raw));
        if (chain.sType == STYPE_SHARED_TEXTURE_MEMORY_IOSURFACE_DESCRIPTOR) {
            return @ptrCast(@alignCast(raw));
        }
        chain_raw = chain.next;
    }
    return null;
}

fn findSharedFenceMTLDescriptor(
    descriptor: *const WGPUSharedFenceDescriptor,
) ?*const WGPUSharedFenceMTLSharedEventDescriptor {
    var chain_raw = descriptor.nextInChain;
    while (chain_raw) |raw| {
        const chain: *const abi_callback.WGPUChainedStruct = @ptrCast(@alignCast(raw));
        if (chain.sType == STYPE_SHARED_FENCE_MTL_SHARED_EVENT_DESCRIPTOR) {
            return @ptrCast(@alignCast(raw));
        }
        chain_raw = chain.next;
    }
    return null;
}

fn enqueueSharedFenceWaits(
    shared_memory: *DoeSharedTextureMemory,
    descriptor: *const WGPUSharedTextureMemoryBeginAccessDescriptor,
) bool {
    if (descriptor.fenceCount == 0) return true;
    _ = shared_memory.queue orelse return false;
    const fences = descriptor.fences orelse return false;
    const signaled_values = descriptor.signaledValues orelse return false;

    for (0..descriptor.fenceCount) |index| {
        const fence = sharedFenceCast(fences[index]) orelse return false;
        const shared_event = fence.shared_event orelse return false;
        // Chromium may invoke BeginAccess from a thread outside Doe's queue
        // submission path. Complete the producer fence before exposing the
        // IOSurface instead of creating a command buffer from that callback.
        metal_bridge_shared_event_wait(shared_event, signaled_values[index]);
    }
    return true;
}

fn wrapCompletionEvent(shared_event: ?*anyopaque, signaled_value: u64) ?CompletionFence {
    const retained_event = metal_bridge_retain(shared_event) orelse return null;
    const fence = native.make(DoeSharedFence) orelse {
        metal_bridge_release(retained_event);
        return null;
    };
    fence.* = .{ .shared_event = retained_event };
    return .{
        .fence = native.toOpaque(fence),
        .signaled_value = signaled_value,
    };
}

fn hasNewQueueCompletion(shared_event: ?*anyopaque, event_counter: u64, access_start_event_counter: u64) bool {
    return shared_event != null and event_counter > access_start_event_counter;
}

fn createCompletionFence(shared_memory: *DoeSharedTextureMemory) ?CompletionFence {
    if (shared_memory.queue) |queue| {
        queue_flush_breakdown.commitStagedWriteBlits(queue);
        if (hasNewQueueCompletion(
            queue.mtl_event,
            queue.event_counter,
            shared_memory.access_start_event_counter,
        )) {
            return wrapCompletionEvent(queue.mtl_event, queue.event_counter);
        }
    }
    const queue = shared_memory.queue orelse return null;
    const shared_event = metal_bridge_device_new_shared_event(queue.dev.mtl_device) orelse return null;
    const command_buffer = metal_bridge_create_command_buffer(queue.dev.mtl_queue) orelse {
        metal_bridge_release(shared_event);
        return null;
    };
    const fence = native.make(DoeSharedFence) orelse {
        metal_bridge_release(command_buffer);
        metal_bridge_release(shared_event);
        return null;
    };

    metal_bridge_command_buffer_encode_signal_event(
        command_buffer,
        shared_event,
        SHARED_FENCE_SIGNAL_VALUE,
    );
    metal_bridge_command_buffer_commit(command_buffer);
    metal_bridge_release(command_buffer);
    fence.* = .{ .shared_event = shared_event };
    return .{
        .fence = native.toOpaque(fence),
        .signaled_value = SHARED_FENCE_SIGNAL_VALUE,
    };
}

fn retainCF(raw: ?*anyopaque) ?*anyopaque {
    if (comptime builtin.os.tag != .macos) return null;
    return CFRetain(raw);
}

fn releaseCF(raw: ?*anyopaque) void {
    if (comptime builtin.os.tag == .macos) {
        CFRelease(raw);
    }
}

fn metalPixelFormatForSharedTexture(format: u32) ?u32 {
    return switch (format) {
        abi_texture.WGPUTextureFormat_RGBA8Unorm => external_texture_ops.MTL_PIXEL_FORMAT_RGBA8_UNORM,
        abi_texture.WGPUTextureFormat_RGBA8UnormSrgb => external_texture_ops.MTL_PIXEL_FORMAT_RGBA8_UNORM_SRGB,
        abi_texture.WGPUTextureFormat_BGRA8Unorm => external_texture_ops.MTL_PIXEL_FORMAT_BGRA8_UNORM,
        abi_texture.WGPUTextureFormat_BGRA8UnormSrgb => external_texture_ops.MTL_PIXEL_FORMAT_BGRA8_UNORM_SRGB,
        else => null,
    };
}

pub fn wgpuDeviceCreateErrorBuffer(
    device: abi_core.WGPUDevice,
    descriptor: ?*const abi_pipeline.WGPUBufferDescriptor,
) callconv(.c) abi_core.WGPUBuffer {
    const dev = native.cast(native.DoeDevice, device) orelse return null;
    const buffer = native.make(native.DoeBuffer) orelse return null;
    const d = descriptor orelse &abi_pipeline.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .usage = abi_core.WGPUBufferUsage_None,
        .size = 0,
        .mappedAtCreation = abi_core.WGPU_FALSE,
    };
    buffer.* = .{
        .error_object = true,
        .backend = dev.backend,
        .size = d.size,
        .usage = d.usage,
    };
    const raw = native.toOpaque(buffer);
    labelOwnedObject(raw, d.label);
    return @ptrCast(raw);
}

pub fn wgpuDeviceCreateErrorTexture(
    device: abi_core.WGPUDevice,
    descriptor: ?*const abi_pipeline.WGPUTextureDescriptor,
) callconv(.c) abi_core.WGPUTexture {
    const dev = native.cast(native.DoeDevice, device) orelse return null;
    const texture = native.make(native.DoeTexture) orelse return null;
    const d = descriptor orelse &abi_pipeline.WGPUTextureDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .usage = abi_texture.WGPUTextureUsage_None,
        .dimension = abi_texture.WGPUTextureDimension_2D,
        .size = .{ .width = 1, .height = 1, .depthOrArrayLayers = 1 },
        .format = abi_texture.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
        .viewFormatCount = 0,
        .viewFormats = null,
    };
    texture.* = .{
        .error_object = true,
        .backend = dev.backend,
        .format = d.format,
        .width = d.size.width,
        .height = d.size.height,
        .depth_or_array_layers = d.size.depthOrArrayLayers,
        .dimension = d.dimension,
        .mip_level_count = d.mipLevelCount,
        .sample_count = d.sampleCount,
        .usage = d.usage,
        .view_format_count = d.viewFormatCount,
    };
    const raw = native.toOpaque(texture);
    labelOwnedObject(raw, d.label);
    return @ptrCast(raw);
}

pub fn wgpuDeviceImportSharedBufferMemory(
    device: abi_core.WGPUDevice,
    descriptor: ?*const WGPUSharedBufferMemoryDescriptor,
) callconv(.c) WGPUSharedBufferMemory {
    _ = device;
    _ = descriptor;
    logUnsupported("wgpuDeviceImportSharedBufferMemory");
    return null;
}

pub fn wgpuDeviceImportSharedFence(
    device: abi_core.WGPUDevice,
    descriptor: ?*const WGPUSharedFenceDescriptor,
) callconv(.c) WGPUSharedFence {
    if (comptime builtin.os.tag != .macos) {
        logUnsupported("wgpuDeviceImportSharedFence(non_macos)");
        return null;
    }
    const dev = native.cast(native.DoeDevice, device) orelse return null;
    if (dev.backend != .metal) return null;
    const desc = descriptor orelse return null;
    const event_desc = findSharedFenceMTLDescriptor(desc) orelse return null;
    const shared_event = metal_bridge_retain(event_desc.sharedEvent) orelse return null;
    const fence = native.make(DoeSharedFence) orelse {
        metal_bridge_release(shared_event);
        return null;
    };
    fence.* = .{ .shared_event = shared_event };
    const raw = native.toOpaque(fence);
    labelOwnedObject(raw, desc.label);
    return @ptrCast(raw);
}

pub fn wgpuDeviceImportSharedTextureMemory(
    device: abi_core.WGPUDevice,
    descriptor: ?*const WGPUSharedTextureMemoryDescriptor,
) callconv(.c) WGPUSharedTextureMemory {
    if (comptime builtin.os.tag != .macos) {
        logUnsupported("wgpuDeviceImportSharedTextureMemory(non_macos)");
        return null;
    }
    const dev = native.cast(native.DoeDevice, device) orelse {
        std.log.err("doe: IOSurface shared texture import rejected invalid device", .{});
        return null;
    };
    const desc = descriptor orelse {
        std.log.err("doe: IOSurface shared texture import missing descriptor", .{});
        return null;
    };
    const ios_desc = findIOSurfaceDescriptor(desc) orelse {
        logUnsupported("wgpuDeviceImportSharedTextureMemory(non_iosurface)");
        return null;
    };
    const iosurface = retainCF(ios_desc.ioSurface) orelse {
        std.log.err("doe: IOSurface shared texture import missing IOSurface handle", .{});
        return null;
    };
    const layout = external_texture_ops.inspectIOSurface(iosurface) orelse {
        std.log.err("doe: IOSurface shared texture import failed layout inspection", .{});
        releaseCF(iosurface);
        return null;
    };
    if (layout.plane_count != 1) {
        std.log.err("doe: IOSurface shared texture import rejected multi-plane surface", .{});
        releaseCF(iosurface);
        return null;
    }
    const queue = dev.queue orelse {
        std.log.err("doe: IOSurface shared texture import requires a live device queue", .{});
        releaseCF(iosurface);
        return null;
    };
    const shared_memory = native.make(DoeSharedTextureMemory) orelse {
        releaseCF(iosurface);
        return null;
    };
    native.doeNativeQueueAddRef(native.toOpaque(queue));
    shared_memory.* = .{
        .backend = dev.backend,
        .queue = queue,
        .iosurface = iosurface,
        .width = layout.width,
        .height = layout.height,
    };
    const raw = native.toOpaque(shared_memory);
    labelOwnedObject(raw, desc.label);
    return raw;
}

pub fn wgpuSharedBufferMemoryBeginAccess(
    shared_buffer_memory: WGPUSharedBufferMemory,
    buffer: abi_core.WGPUBuffer,
    descriptor: ?*const WGPUSharedBufferMemoryBeginAccessDescriptor,
) callconv(.c) abi_core.WGPUStatus {
    _ = shared_buffer_memory;
    _ = buffer;
    _ = descriptor;
    return WGPUStatus_Error;
}

pub fn wgpuSharedBufferMemoryCreateBuffer(
    shared_buffer_memory: WGPUSharedBufferMemory,
    descriptor: ?*const abi_pipeline.WGPUBufferDescriptor,
) callconv(.c) abi_core.WGPUBuffer {
    _ = shared_buffer_memory;
    _ = descriptor;
    return null;
}

pub fn wgpuSharedBufferMemoryEndAccess(
    shared_buffer_memory: WGPUSharedBufferMemory,
    buffer: abi_core.WGPUBuffer,
    descriptor: ?*WGPUSharedBufferMemoryEndAccessState,
) callconv(.c) abi_core.WGPUStatus {
    _ = shared_buffer_memory;
    _ = buffer;
    if (descriptor) |state| {
        state.initialized = abi_core.WGPU_FALSE;
        state.fenceCount = 0;
        state.fences = null;
        state.signaledValues = null;
    }
    return WGPUStatus_Error;
}

pub fn wgpuSharedBufferMemoryGetProperties(
    shared_buffer_memory: WGPUSharedBufferMemory,
    properties: ?*WGPUSharedBufferMemoryProperties,
) callconv(.c) abi_core.WGPUStatus {
    _ = shared_buffer_memory;
    if (properties) |out| {
        out.size = 0;
        out.usage = 0;
    }
    return WGPUStatus_Error;
}

pub fn wgpuSharedBufferMemoryIsDeviceLost(shared_buffer_memory: WGPUSharedBufferMemory) callconv(.c) abi_core.WGPUBool {
    _ = shared_buffer_memory;
    return abi_core.WGPU_TRUE;
}

pub fn wgpuSharedBufferMemorySetLabel(shared_buffer_memory: WGPUSharedBufferMemory, label: abi_core.WGPUStringView) callconv(.c) void {
    _ = shared_buffer_memory;
    _ = label;
}

pub fn wgpuSharedBufferMemoryAddRef(shared_buffer_memory: WGPUSharedBufferMemory) callconv(.c) void {
    _ = shared_buffer_memory;
}

pub fn wgpuSharedBufferMemoryRelease(shared_buffer_memory: WGPUSharedBufferMemory) callconv(.c) void {
    _ = shared_buffer_memory;
}

pub fn wgpuSharedBufferMemoryEndAccessStateFreeMembers(state: WGPUSharedBufferMemoryEndAccessState) callconv(.c) void {
    _ = state;
}

pub fn wgpuSharedFenceExportInfo(shared_fence: WGPUSharedFence, info: ?*WGPUSharedFenceExportInfo) callconv(.c) void {
    const fence = sharedFenceCast(shared_fence) orelse return;
    const out = info orelse return;
    out.type = SHARED_FENCE_TYPE_MTL_SHARED_EVENT;
    var chain_raw = out.nextInChain;
    while (chain_raw) |raw| {
        const chain: *abi_callback.WGPUChainedStruct = @ptrCast(@alignCast(raw));
        if (chain.sType == STYPE_SHARED_FENCE_MTL_SHARED_EVENT_EXPORT_INFO) {
            const event_info: *WGPUSharedFenceMTLSharedEventExportInfo = @ptrCast(@alignCast(raw));
            event_info.sharedEvent = fence.shared_event;
            return;
        }
        chain_raw = @constCast(chain.next);
    }
}

pub fn wgpuSharedFenceAddRef(shared_fence: WGPUSharedFence) callconv(.c) void {
    const fence = sharedFenceCast(shared_fence) orelse return;
    fence.ref_count +|= 1;
}

pub fn wgpuSharedFenceRelease(shared_fence: WGPUSharedFence) callconv(.c) void {
    const fence = sharedFenceCast(shared_fence) orelse return;
    if (!native.object_should_destroy(fence)) return;
    native.label_store.remove(shared_fence);
    if (fence.shared_event) |shared_event| {
        metal_bridge_release(shared_event);
    }
    native.alloc.destroy(fence);
}

pub fn wgpuSharedFenceSetLabel(shared_fence: WGPUSharedFence, label: abi_core.WGPUStringView) callconv(.c) void {
    if (sharedFenceCast(shared_fence) != null) {
        labelOwnedObject(shared_fence, label);
    }
}

pub fn wgpuSharedTextureMemoryBeginAccess(
    shared_texture_memory: WGPUSharedTextureMemory,
    texture: abi_core.WGPUTexture,
    descriptor: ?*const WGPUSharedTextureMemoryBeginAccessDescriptor,
) callconv(.c) abi_core.WGPUStatus {
    const shared_memory = sharedTextureMemoryCast(shared_texture_memory) orelse {
        std.log.err("doe: IOSurface begin access rejected invalid shared memory", .{});
        return WGPUStatus_Error;
    };
    const tex = native.cast(native.DoeTexture, texture) orelse {
        std.log.err("doe: IOSurface begin access rejected invalid texture", .{});
        return WGPUStatus_Error;
    };
    if (shared_memory.in_access or tex.error_object or tex.mtl == null) {
        std.log.err("doe: IOSurface begin access rejected state in_access={} error_object={} has_metal_texture={}", .{ shared_memory.in_access, tex.error_object, tex.mtl != null });
        return WGPUStatus_Error;
    }
    if (descriptor) |desc| {
        if (!enqueueSharedFenceWaits(shared_memory, desc)) {
            std.log.err("doe: IOSurface begin access failed to enqueue shared-event waits", .{});
            return WGPUStatus_Error;
        }
    }
    shared_memory.access_start_event_counter = if (shared_memory.queue) |queue|
        queue.event_counter
    else
        0;
    shared_memory.in_access = true;
    return abi_core.WGPUStatus_Success;
}

pub fn wgpuSharedTextureMemoryCreateTexture(
    shared_texture_memory: WGPUSharedTextureMemory,
    descriptor: ?*const abi_pipeline.WGPUTextureDescriptor,
) callconv(.c) abi_core.WGPUTexture {
    const shared_memory = sharedTextureMemoryCast(shared_texture_memory) orelse {
        std.log.err("doe: IOSurface texture creation rejected invalid shared memory", .{});
        return null;
    };
    const desc = descriptor orelse {
        std.log.err("doe: IOSurface texture creation missing descriptor", .{});
        return null;
    };
    const metal_pixel_format = metalPixelFormatForSharedTexture(desc.format) orelse {
        std.log.err("doe: IOSurface texture creation rejected unsupported format={}", .{desc.format});
        return null;
    };
    if ((shared_memory.format != abi_texture.WGPUTextureFormat_Undefined and desc.format != shared_memory.format) or
        desc.dimension != abi_texture.WGPUTextureDimension_2D or
        desc.size.width != shared_memory.width or
        desc.size.height != shared_memory.height or
        desc.size.depthOrArrayLayers != 1 or
        desc.mipLevelCount != 1 or
        desc.sampleCount != 1)
    {
        std.log.err(
            "doe: IOSurface texture descriptor mismatch format={}/{} size={}x{}/{}x{} depth={} dimension={} mips={} samples={}",
            .{ desc.format, shared_memory.format, desc.size.width, desc.size.height, shared_memory.width, shared_memory.height, desc.size.depthOrArrayLayers, desc.dimension, desc.mipLevelCount, desc.sampleCount },
        );
        return null;
    }
    const imported = external_texture_ops.importIOSurfaceWithPixelFormat(
        (shared_memory.queue orelse return null).dev.mtl_device,
        shared_memory.iosurface,
        metal_pixel_format,
    ) orelse {
        std.log.err("doe: IOSurface texture creation failed Metal plane import", .{});
        return null;
    };
    if (!imported.is_single_plane) {
        external_texture_ops.releasePlanes(imported);
        return null;
    }

    const texture = native.make(native.DoeTexture) orelse {
        external_texture_ops.releasePlanes(imported);
        return null;
    };
    texture.* = .{
        .error_object = false,
        .backend = shared_memory.backend,
        .mtl = imported.plane0,
        .format = desc.format,
        .width = desc.size.width,
        .height = desc.size.height,
        .depth_or_array_layers = desc.size.depthOrArrayLayers,
        .dimension = desc.dimension,
        .mip_level_count = desc.mipLevelCount,
        .sample_count = desc.sampleCount,
        .usage = desc.usage,
        .view_format_count = desc.viewFormatCount,
    };
    shared_memory.format = desc.format;
    const raw = native.toOpaque(texture);
    if (!texture_sampler.registerImportedTexture(raw)) {
        external_texture_ops.metal_bridge_release(texture.mtl);
        native.alloc.destroy(texture);
        return null;
    }
    labelOwnedObject(raw, desc.label);
    return @ptrCast(raw);
}

test "shared IOSurface formats map to the matching Metal channel order" {
    try std.testing.expectEqual(
        @as(?u32, external_texture_ops.MTL_PIXEL_FORMAT_RGBA8_UNORM),
        metalPixelFormatForSharedTexture(abi_texture.WGPUTextureFormat_RGBA8Unorm),
    );
    try std.testing.expectEqual(
        @as(?u32, external_texture_ops.MTL_PIXEL_FORMAT_BGRA8_UNORM),
        metalPixelFormatForSharedTexture(abi_texture.WGPUTextureFormat_BGRA8Unorm),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        metalPixelFormatForSharedTexture(abi_texture.WGPUTextureFormat_R8Unorm),
    );
}

test "shared IOSurface completion fences never reuse a pre-access timeline value" {
    const event: ?*anyopaque = @ptrFromInt(1);
    try std.testing.expect(!hasNewQueueCompletion(event, 9, 9));
    try std.testing.expect(!hasNewQueueCompletion(event, 8, 9));
    try std.testing.expect(!hasNewQueueCompletion(null, 10, 9));
    try std.testing.expect(hasNewQueueCompletion(event, 10, 9));
}

pub fn wgpuSharedTextureMemoryEndAccess(
    shared_texture_memory: WGPUSharedTextureMemory,
    texture: abi_core.WGPUTexture,
    descriptor: ?*WGPUSharedTextureMemoryEndAccessState,
) callconv(.c) abi_core.WGPUStatus {
    const shared_memory = sharedTextureMemoryCast(shared_texture_memory) orelse return WGPUStatus_Error;
    const tex = native.cast(native.DoeTexture, texture) orelse return WGPUStatus_Error;
    if (!shared_memory.in_access or tex.error_object or tex.mtl == null) return WGPUStatus_Error;

    if (descriptor) |state| {
        const fences = native.alloc.alloc(WGPUSharedFence, 1) catch return WGPUStatus_Error;
        const signaled_values = native.alloc.alloc(u64, 1) catch {
            native.alloc.free(fences);
            return WGPUStatus_Error;
        };
        const completion = createCompletionFence(shared_memory) orelse {
            native.alloc.free(signaled_values);
            native.alloc.free(fences);
            return WGPUStatus_Error;
        };
        fences[0] = completion.fence;
        signaled_values[0] = completion.signaled_value;
        state.initialized = abi_core.WGPU_TRUE;
        state.fenceCount = 1;
        state.fences = fences.ptr;
        state.signaledValues = signaled_values.ptr;
    }
    shared_memory.in_access = false;
    return abi_core.WGPUStatus_Success;
}

pub fn wgpuSharedTextureMemoryGetProperties(
    shared_texture_memory: WGPUSharedTextureMemory,
    properties: ?*WGPUSharedTextureMemoryProperties,
) callconv(.c) abi_core.WGPUStatus {
    const shared_memory = sharedTextureMemoryCast(shared_texture_memory) orelse return WGPUStatus_Error;
    if (properties) |out| {
        out.usage = shared_memory.usage;
        out.size = .{
            .width = shared_memory.width,
            .height = shared_memory.height,
            .depthOrArrayLayers = 1,
        };
        out.format = shared_memory.format;
    }
    return abi_core.WGPUStatus_Success;
}

pub fn wgpuSharedTextureMemoryIsDeviceLost(shared_texture_memory: WGPUSharedTextureMemory) callconv(.c) abi_core.WGPUBool {
    if (sharedTextureMemoryCast(shared_texture_memory) == null) {
        return abi_core.WGPU_TRUE;
    }
    return abi_core.WGPU_FALSE;
}

pub fn wgpuSharedTextureMemorySetLabel(shared_texture_memory: WGPUSharedTextureMemory, label: abi_core.WGPUStringView) callconv(.c) void {
    if (sharedTextureMemoryCast(shared_texture_memory) != null) {
        labelOwnedObject(shared_texture_memory, label);
    }
}

pub fn wgpuSharedTextureMemoryAddRef(shared_texture_memory: WGPUSharedTextureMemory) callconv(.c) void {
    const shared_memory = sharedTextureMemoryCast(shared_texture_memory) orelse return;
    shared_memory.ref_count +|= 1;
}

pub fn wgpuSharedTextureMemoryRelease(shared_texture_memory: WGPUSharedTextureMemory) callconv(.c) void {
    const shared_memory = sharedTextureMemoryCast(shared_texture_memory) orelse return;
    if (!native.object_should_destroy(shared_memory)) return;
    native.label_store.remove(shared_texture_memory);
    if (shared_memory.iosurface) |iosurface| {
        releaseCF(iosurface);
    }
    if (shared_memory.queue) |queue| {
        native.doeNativeQueueRelease(native.toOpaque(queue));
    }
    native.alloc.destroy(shared_memory);
}

pub fn wgpuSharedTextureMemoryEndAccessStateFreeMembers(state: WGPUSharedTextureMemoryEndAccessState) callconv(.c) void {
    if (state.fenceCount == 0) return;
    if (state.fences) |fence_ptr| {
        const fences = @constCast(fence_ptr)[0..state.fenceCount];
        for (fences) |fence| {
            wgpuSharedFenceRelease(fence);
        }
        native.alloc.free(fences);
    }
    if (state.signaledValues) |value_ptr| {
        native.alloc.free(@constCast(value_ptr)[0..state.fenceCount]);
    }
}

test "browser error object procs return Doe-owned releasable handles" {
    var device = native.DoeDevice{};
    const device_raw = native.toOpaque(&device);

    const buffer_desc = abi_pipeline.WGPUBufferDescriptor{
        .nextInChain = null,
        .label = .{ .data = "error-buffer".ptr, .length = "error-buffer".len },
        .usage = abi_core.WGPUBufferUsage_CopyDst,
        .size = 64,
        .mappedAtCreation = abi_core.WGPU_FALSE,
    };
    const buffer_raw = wgpuDeviceCreateErrorBuffer(device_raw, &buffer_desc);
    const buffer = native.cast(native.DoeBuffer, buffer_raw) orelse return error.TestExpectedEqual;
    try std.testing.expect(buffer.error_object);
    try std.testing.expectEqual(device.backend, buffer.backend);
    try std.testing.expectEqual(buffer_desc.size, buffer.size);
    try std.testing.expectEqual(buffer_desc.usage, buffer.usage);
    native.doeNativeBufferRelease(buffer_raw);

    const texture_desc = abi_pipeline.WGPUTextureDescriptor{
        .nextInChain = null,
        .label = .{ .data = "error-texture".ptr, .length = "error-texture".len },
        .usage = abi_texture.WGPUTextureUsage_TextureBinding,
        .dimension = abi_texture.WGPUTextureDimension_2D,
        .size = .{ .width = 4, .height = 2, .depthOrArrayLayers = 1 },
        .format = abi_texture.WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
        .viewFormatCount = 0,
        .viewFormats = null,
    };
    const texture_raw = wgpuDeviceCreateErrorTexture(device_raw, &texture_desc);
    const texture = native.cast(native.DoeTexture, texture_raw) orelse return error.TestExpectedEqual;
    try std.testing.expect(texture.error_object);
    try std.testing.expectEqual(device.backend, texture.backend);
    try std.testing.expectEqual(texture_desc.format, texture.format);
    try std.testing.expectEqual(texture_desc.size.width, texture.width);
    try std.testing.expectEqual(texture_desc.size.height, texture.height);
    try std.testing.expectEqual(texture_desc.usage, texture.usage);
    try std.testing.expectEqual(@as(abi_core.WGPUTextureView, null), native.doeNativeTextureCreateView(texture_raw, null));
    native.doeNativeTextureRelease(texture_raw);
}
