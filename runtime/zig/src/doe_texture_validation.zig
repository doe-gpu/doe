const std = @import("std");
const abi_callback = @import("core/abi/wgpu_callback_descriptor_types.zig");
const abi_core = @import("core/abi/wgpu_core_base_types.zig");
const abi_pipeline = @import("core/abi/wgpu_pipeline_descriptor_types.zig");
const abi_texture = @import("core/abi/wgpu_texture_base_types.zig");
const device_caps = @import("doe_device_caps.zig");
const native_types = @import("doe_native_object_types.zig");

const DoeDevice = native_types.DoeDevice;
const MAX_TEXTURE_DESCRIPTOR_CHAIN_NODES: u32 = 16;
const VALID_TEXTURE_USAGE = abi_texture.WGPUTextureUsage_CopySrc |
    abi_texture.WGPUTextureUsage_CopyDst |
    abi_texture.WGPUTextureUsage_TextureBinding |
    abi_texture.WGPUTextureUsage_StorageBinding |
    abi_texture.WGPUTextureUsage_RenderAttachment |
    abi_texture.WGPUTextureUsage_TransientAttachment |
    abi_texture.WGPUTextureUsage_StorageAttachment;

pub fn effectiveTextureUsage(desc: *const abi_pipeline.WGPUTextureDescriptor) u64 {
    var usage = desc.usage;
    var visited: u32 = 0;
    var chain = if (desc.nextInChain) |raw|
        @as(*const abi_pipeline.WGPUChainedStruct, @ptrCast(@alignCast(raw)))
    else
        null;

    while (chain) |node| : (visited += 1) {
        if (visited >= MAX_TEXTURE_DESCRIPTOR_CHAIN_NODES) return usage;
        if (node.sType == abi_pipeline.WGPUSType_DawnTextureInternalUsageDescriptor) {
            const internal: *const abi_pipeline.WGPUDawnTextureInternalUsageDescriptor =
                @ptrCast(@alignCast(node));
            usage |= internal.internalUsage;
        }
        chain = node.next;
    }
    return usage;
}

fn chainIsValid(desc: *const abi_pipeline.WGPUTextureDescriptor) bool {
    var visited: u32 = 0;
    var chain = if (desc.nextInChain) |raw|
        @as(*const abi_pipeline.WGPUChainedStruct, @ptrCast(@alignCast(raw)))
    else
        null;
    while (chain) |node| : (visited += 1) {
        if (visited >= MAX_TEXTURE_DESCRIPTOR_CHAIN_NODES) return false;
        if (node.sType != abi_pipeline.WGPUSType_DawnTextureInternalUsageDescriptor) return false;
        chain = node.next;
    }
    return true;
}

fn isKnownFormat(format: u32) bool {
    return format >= abi_texture.WGPUTextureFormat_R8Unorm and
        format <= abi_texture.WGPUTextureFormat_ASTC12x12UnormSrgb;
}

fn isViewFormatCompatible(base: u32, view: u32) bool {
    if (base == view) return true;
    return (base == abi_texture.WGPUTextureFormat_RGBA8Unorm and view == abi_texture.WGPUTextureFormat_RGBA8UnormSrgb) or
        (base == abi_texture.WGPUTextureFormat_RGBA8UnormSrgb and view == abi_texture.WGPUTextureFormat_RGBA8Unorm) or
        (base == abi_texture.WGPUTextureFormat_BGRA8Unorm and view == abi_texture.WGPUTextureFormat_BGRA8UnormSrgb) or
        (base == abi_texture.WGPUTextureFormat_BGRA8UnormSrgb and view == abi_texture.WGPUTextureFormat_BGRA8Unorm);
}

fn maxMipLevelCount(desc: *const abi_pipeline.WGPUTextureDescriptor) u32 {
    const max_extent = switch (desc.dimension) {
        abi_texture.WGPUTextureDimension_1D => desc.size.width,
        abi_texture.WGPUTextureDimension_3D => @max(desc.size.width, @max(desc.size.height, desc.size.depthOrArrayLayers)),
        else => @max(desc.size.width, desc.size.height),
    };
    return @as(u32, @intCast(@bitSizeOf(u32) - @clz(max_extent)));
}

pub fn validateTextureDescriptor(
    device: *DoeDevice,
    desc: *const abi_pipeline.WGPUTextureDescriptor,
) ?[]const u8 {
    if (!chainIsValid(desc)) return "texture descriptor contains an unsupported or cyclic chain";
    const usage = effectiveTextureUsage(desc);
    if (desc.usage == abi_texture.WGPUTextureUsage_None) return "texture usage must not be zero";
    if ((usage & ~VALID_TEXTURE_USAGE) != 0) return "texture usage contains unsupported flags";
    if (!isKnownFormat(desc.format)) return "texture format is undefined or unsupported";
    if (desc.size.width == 0 or desc.size.height == 0 or desc.size.depthOrArrayLayers == 0)
        return "texture extent must be non-zero";
    if (desc.mipLevelCount == 0) return "texture mip level count must be non-zero";
    if (desc.sampleCount != 1 and desc.sampleCount != 4) return "texture sample count must be 1 or 4";

    var limits: abi_callback.WGPULimits = undefined;
    _ = device_caps.doeNativeDeviceGetLimits(@ptrCast(device), &limits);
    switch (desc.dimension) {
        abi_texture.WGPUTextureDimension_1D => {
            if (desc.size.width > limits.maxTextureDimension1D or
                desc.size.height != 1 or desc.size.depthOrArrayLayers != 1)
                return "1D texture extent exceeds device limits or has non-unit height/layers";
        },
        abi_texture.WGPUTextureDimension_2D => {
            if (desc.size.width > limits.maxTextureDimension2D or
                desc.size.height > limits.maxTextureDimension2D or
                desc.size.depthOrArrayLayers > limits.maxTextureArrayLayers)
                return "2D texture extent exceeds device limits";
        },
        abi_texture.WGPUTextureDimension_3D => {
            if (desc.size.width > limits.maxTextureDimension3D or
                desc.size.height > limits.maxTextureDimension3D or
                desc.size.depthOrArrayLayers > limits.maxTextureDimension3D)
                return "3D texture extent exceeds device limits";
        },
        else => return "texture dimension is undefined or unsupported",
    }

    if (desc.mipLevelCount > maxMipLevelCount(desc)) return "texture mip level count exceeds its extent";
    if (desc.sampleCount > 1 and
        (desc.dimension != abi_texture.WGPUTextureDimension_2D or
            desc.size.depthOrArrayLayers != 1 or
            desc.mipLevelCount != 1 or
            (usage & (abi_texture.WGPUTextureUsage_CopySrc |
                abi_texture.WGPUTextureUsage_CopyDst |
                abi_texture.WGPUTextureUsage_StorageBinding)) != 0))
        return "multisampled texture descriptor has an incompatible dimension, extent, mip count, or usage";
    if (abi_texture.isDepthStencilFormat(desc.format) and desc.dimension != abi_texture.WGPUTextureDimension_2D)
        return "depth-stencil textures must be 2D";
    if ((abi_texture.isBCFormat(desc.format) or abi_texture.isETC2Format(desc.format) or abi_texture.isASTCFormat(desc.format)) and
        desc.dimension == abi_texture.WGPUTextureDimension_1D)
        return "compressed textures cannot be 1D";

    if (desc.viewFormatCount > 0) {
        const view_formats = desc.viewFormats orelse return "texture view formats pointer is null";
        for (view_formats[0..desc.viewFormatCount]) |view_format| {
            if (!isKnownFormat(view_format) or !isViewFormatCompatible(desc.format, view_format))
                return "texture view format is incompatible with the base format";
        }
    }
    return null;
}

test "browser canvas texture descriptor validates locally" {
    var device: DoeDevice = .{};
    var internal = abi_pipeline.WGPUDawnTextureInternalUsageDescriptor{
        .chain = .{ .next = null, .sType = abi_pipeline.WGPUSType_DawnTextureInternalUsageDescriptor },
        .internalUsage = abi_texture.WGPUTextureUsage_CopySrc | abi_texture.WGPUTextureUsage_CopyDst,
    };
    const view_formats = [_]u32{abi_texture.WGPUTextureFormat_BGRA8UnormSrgb};
    var desc = abi_pipeline.WGPUTextureDescriptor{
        .nextInChain = @ptrCast(&internal.chain),
        .label = .{ .data = null, .length = 0 },
        .usage = abi_texture.WGPUTextureUsage_RenderAttachment,
        .dimension = abi_texture.WGPUTextureDimension_2D,
        .size = .{ .width = 1280, .height = 720, .depthOrArrayLayers = 1 },
        .format = abi_texture.WGPUTextureFormat_BGRA8Unorm,
        .mipLevelCount = 1,
        .sampleCount = 1,
        .viewFormatCount = view_formats.len,
        .viewFormats = &view_formats,
    };

    try std.testing.expect(validateTextureDescriptor(&device, &desc) == null);
    desc.size.width = 0;
    try std.testing.expect(validateTextureDescriptor(&device, &desc) != null);
}
