const std = @import("std");
const model_resource_types = @import("../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../contracts/model/model_compute_types.zig");
const model_texture_types = @import("../contracts/model/model_texture_value_types.zig");
const model_binding_types = @import("../contracts/model/model_binding_value_types.zig");
const model_render_types = @import("../contracts/model/model_render_types.zig");
const compressed_formats = @import("../contracts/texture_format.zig");

pub const ParseError = error{
    InvalidCommandPayload,
    OutOfMemory,
};

fn eqIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.eqlIgnoreCase(lhs, rhs);
}

pub fn parseCopyResourceKind(raw_kind: ?[]const u8) ?model_resource_types.CopyResourceKind {
    const raw_value = raw_kind orelse return null;
    if (eqIgnoreCase(raw_value, "buffer")) return .buffer;
    if (eqIgnoreCase(raw_value, "texture")) return .texture;
    return null;
}

pub fn parseCopyDirection(raw_direction: ?[]const u8, command_name: ?[]const u8) ParseError!model_resource_types.CopyDirection {
    if (raw_direction) |raw_value| {
        if (eqIgnoreCase(raw_value, "buffer_to_buffer")) return .buffer_to_buffer;
        if (eqIgnoreCase(raw_value, "buffer_to_texture")) return .buffer_to_texture;
        if (eqIgnoreCase(raw_value, "texture_to_buffer")) return .texture_to_buffer;
        if (eqIgnoreCase(raw_value, "texture_to_texture")) return .texture_to_texture;
        return ParseError.InvalidCommandPayload;
    }

    const kind = command_name orelse return .buffer_to_buffer;
    if (eqIgnoreCase(kind, "copy_buffer_to_texture") or eqIgnoreCase(kind, "copy_texture") or eqIgnoreCase(kind, "copyBufferToTexture") or eqIgnoreCase(kind, "copyTexture")) {
        return .buffer_to_texture;
    }
    if (eqIgnoreCase(kind, "copy_texture_to_buffer") or eqIgnoreCase(kind, "copyTextureToBuffer")) {
        return .texture_to_buffer;
    }
    if (eqIgnoreCase(kind, "copy_texture_to_texture") or eqIgnoreCase(kind, "copyTextureToTexture")) {
        return .texture_to_texture;
    }
    return .buffer_to_buffer;
}

pub fn parseKernelBindingKind(raw_kind: ?[]const u8) ?model_compute_types.KernelBindingResourceKind {
    const value = raw_kind orelse return .buffer;
    if (eqIgnoreCase(value, "buffer") or eqIgnoreCase(value, "uniform") or eqIgnoreCase(value, "storage_buffer") or eqIgnoreCase(value, "readonly_storage_buffer")) {
        return .buffer;
    }
    if (eqIgnoreCase(value, "texture") or eqIgnoreCase(value, "sampled_texture") or eqIgnoreCase(value, "texture_sampled")) {
        return .texture;
    }
    if (eqIgnoreCase(value, "storage_texture") or eqIgnoreCase(value, "storage_texture_binding") or eqIgnoreCase(value, "storage")) {
        return .storage_texture;
    }
    if (eqIgnoreCase(value, "sampler") or eqIgnoreCase(value, "filtering_sampler") or eqIgnoreCase(value, "non_filtering_sampler") or eqIgnoreCase(value, "comparison_sampler")) {
        return .sampler;
    }
    return null;
}

pub fn parseKernelDispatchRepeatSynchronization(raw: ?[]const u8) ParseError!model_compute_types.KernelDispatchRepeatSynchronization {
    const value = raw orelse return .dependent;
    if (eqIgnoreCase(value, "dependent") or eqIgnoreCase(value, "inter-dispatch-barrier") or eqIgnoreCase(value, "inter_dispatch_barrier")) {
        return .dependent;
    }
    if (eqIgnoreCase(value, "independent") or eqIgnoreCase(value, "none")) {
        return .independent;
    }
    return ParseError.InvalidCommandPayload;
}

pub fn parseShaderStage(raw_stage: ?[]const u8) ?model_texture_types.WGPUFlags {
    const value = raw_stage orelse return null;
    if (eqIgnoreCase(value, "compute") or eqIgnoreCase(value, "compute-only") or eqIgnoreCase(value, "computeOnly")) {
        return model_binding_types.WGPUShaderStage_Compute;
    }
    if (eqIgnoreCase(value, "vertex")) return model_binding_types.WGPUShaderStage_Vertex;
    if (eqIgnoreCase(value, "fragment")) return model_binding_types.WGPUShaderStage_Fragment;
    if (eqIgnoreCase(value, "all") or eqIgnoreCase(value, "*")) return model_binding_types.WGPUShaderStage_Vertex | model_binding_types.WGPUShaderStage_Fragment | model_binding_types.WGPUShaderStage_Compute;
    return null;
}

pub fn parseWGPUBits(raw_bits: ?u64) ?model_texture_types.WGPUFlags {
    return raw_bits;
}

pub fn parseBufferBindingType(raw: ?[]const u8) u32 {
    const value = raw orelse return model_binding_types.WGPUBufferBindingType_Undefined;
    if (eqIgnoreCase(value, "uniform")) return model_binding_types.WGPUBufferBindingType_Uniform;
    if (eqIgnoreCase(value, "storage")) return model_binding_types.WGPUBufferBindingType_Storage;
    if (eqIgnoreCase(value, "readonly") or eqIgnoreCase(value, "read_only_storage")) return model_binding_types.WGPUBufferBindingType_ReadOnlyStorage;
    return model_binding_types.WGPUBufferBindingType_Undefined;
}

pub fn parseTextureSampleType(raw: ?[]const u8) u32 {
    const value = raw orelse return model_binding_types.WGPUTextureSampleType_Undefined;
    if (eqIgnoreCase(value, "float")) return model_binding_types.WGPUTextureSampleType_Float;
    if (eqIgnoreCase(value, "unfilterable-float") or eqIgnoreCase(value, "unfilterable_float")) return model_binding_types.WGPUTextureSampleType_UnfilterableFloat;
    if (eqIgnoreCase(value, "depth")) return model_binding_types.WGPUTextureSampleType_Depth;
    if (eqIgnoreCase(value, "sint")) return model_binding_types.WGPUTextureSampleType_Sint;
    if (eqIgnoreCase(value, "uint")) return model_binding_types.WGPUTextureSampleType_Uint;
    return model_binding_types.WGPUTextureSampleType_Undefined;
}

pub fn parseTextureViewDimension(raw: ?[]const u8) u32 {
    const value = raw orelse return model_texture_types.WGPUTextureViewDimension_Undefined;
    if (eqIgnoreCase(value, "1d") or eqIgnoreCase(value, "1D") or eqIgnoreCase(value, "1d-array")) return model_texture_types.WGPUTextureViewDimension_1D;
    if (eqIgnoreCase(value, "2d") or eqIgnoreCase(value, "2D")) return model_texture_types.WGPUTextureViewDimension_2D;
    if (eqIgnoreCase(value, "2d-array")) return model_texture_types.WGPUTextureViewDimension_2DArray;
    if (eqIgnoreCase(value, "cube")) return model_texture_types.WGPUTextureViewDimension_Cube;
    if (eqIgnoreCase(value, "cube-array")) return model_texture_types.WGPUTextureViewDimension_CubeArray;
    if (eqIgnoreCase(value, "3d") or eqIgnoreCase(value, "3D")) return model_texture_types.WGPUTextureViewDimension_3D;
    return model_texture_types.WGPUTextureViewDimension_Undefined;
}

pub fn parseTextureDimension(raw: ?[]const u8) u32 {
    const value = raw orelse return model_texture_types.WGPUTextureDimension_Undefined;
    if (eqIgnoreCase(value, "1d")) return model_texture_types.WGPUTextureDimension_1D;
    if (eqIgnoreCase(value, "2d")) return model_texture_types.WGPUTextureDimension_2D;
    if (eqIgnoreCase(value, "3d")) return model_texture_types.WGPUTextureDimension_3D;
    return model_texture_types.WGPUTextureDimension_Undefined;
}

pub fn parseStorageTextureAccess(raw: ?[]const u8) u32 {
    const value = raw orelse return model_binding_types.WGPUStorageTextureAccess_Undefined;
    if (eqIgnoreCase(value, "write_only") or eqIgnoreCase(value, "write-only")) return model_binding_types.WGPUStorageTextureAccess_WriteOnly;
    if (eqIgnoreCase(value, "read_only") or eqIgnoreCase(value, "read-only")) return model_binding_types.WGPUStorageTextureAccess_ReadOnly;
    if (eqIgnoreCase(value, "read_write") or eqIgnoreCase(value, "read-write")) return model_binding_types.WGPUStorageTextureAccess_ReadWrite;
    return model_binding_types.WGPUStorageTextureAccess_Undefined;
}

pub fn parseTextureAspect(raw: ?[]const u8) u32 {
    const value = raw orelse return model_texture_types.WGPUTextureAspect_Undefined;
    if (eqIgnoreCase(value, "all")) return model_texture_types.WGPUTextureAspect_All;
    if (eqIgnoreCase(value, "depth-only") or eqIgnoreCase(value, "depth_only") or eqIgnoreCase(value, "depth")) return model_texture_types.WGPUTextureAspect_DepthOnly;
    if (eqIgnoreCase(value, "stencil-only") or eqIgnoreCase(value, "stencil_only") or eqIgnoreCase(value, "stencil")) return model_texture_types.WGPUTextureAspect_StencilOnly;
    return model_texture_types.WGPUTextureAspect_Undefined;
}

pub fn parseTextureFormat(raw: []const u8) ParseError!u32 {
    if (raw.len == 0) return model_texture_types.WGPUTextureFormat_Undefined;
    if (eqIgnoreCase(raw, "r8unorm")) return model_texture_types.WGPUTextureFormat_R8Unorm;
    if (eqIgnoreCase(raw, "r8snorm")) return model_texture_types.WGPUTextureFormat_R8Snorm;
    if (eqIgnoreCase(raw, "r8uint")) return model_texture_types.WGPUTextureFormat_R8Uint;
    if (eqIgnoreCase(raw, "r8sint")) return model_texture_types.WGPUTextureFormat_R8Sint;
    if (eqIgnoreCase(raw, "r16unorm")) return model_texture_types.WGPUTextureFormat_R16Unorm;
    if (eqIgnoreCase(raw, "r16snorm")) return model_texture_types.WGPUTextureFormat_R16Snorm;
    if (eqIgnoreCase(raw, "r16uint")) return model_texture_types.WGPUTextureFormat_R16Uint;
    if (eqIgnoreCase(raw, "r16sint")) return model_texture_types.WGPUTextureFormat_R16Sint;
    if (eqIgnoreCase(raw, "r16float")) return model_texture_types.WGPUTextureFormat_R16Float;
    if (eqIgnoreCase(raw, "rg8unorm")) return model_texture_types.WGPUTextureFormat_RG8Unorm;
    if (eqIgnoreCase(raw, "rg8snorm")) return model_texture_types.WGPUTextureFormat_RG8Snorm;
    if (eqIgnoreCase(raw, "rg8uint")) return model_texture_types.WGPUTextureFormat_RG8Uint;
    if (eqIgnoreCase(raw, "rg8sint")) return model_texture_types.WGPUTextureFormat_RG8Sint;
    if (eqIgnoreCase(raw, "r32float")) return model_texture_types.WGPUTextureFormat_R32Float;
    if (eqIgnoreCase(raw, "r32uint")) return model_texture_types.WGPUTextureFormat_R32Uint;
    if (eqIgnoreCase(raw, "r32sint")) return model_texture_types.WGPUTextureFormat_R32Sint;
    if (eqIgnoreCase(raw, "rg16unorm")) return model_texture_types.WGPUTextureFormat_RG16Unorm;
    if (eqIgnoreCase(raw, "rg16snorm")) return model_texture_types.WGPUTextureFormat_RG16Snorm;
    if (eqIgnoreCase(raw, "rg16uint")) return model_texture_types.WGPUTextureFormat_RG16Uint;
    if (eqIgnoreCase(raw, "rg16sint")) return model_texture_types.WGPUTextureFormat_RG16Sint;
    if (eqIgnoreCase(raw, "rg16float")) return model_texture_types.WGPUTextureFormat_RG16Float;
    if (eqIgnoreCase(raw, "rgba8unorm")) return model_texture_types.WGPUTextureFormat_RGBA8Unorm;
    if (eqIgnoreCase(raw, "rgba8unorm-srgb") or eqIgnoreCase(raw, "rgba8unormsrgb")) return model_texture_types.WGPUTextureFormat_RGBA8UnormSrgb;
    if (eqIgnoreCase(raw, "rgba8snorm")) return model_texture_types.WGPUTextureFormat_RGBA8Snorm;
    if (eqIgnoreCase(raw, "rgba8uint")) return model_texture_types.WGPUTextureFormat_RGBA8Uint;
    if (eqIgnoreCase(raw, "rgba8sint")) return model_texture_types.WGPUTextureFormat_RGBA8Sint;
    if (eqIgnoreCase(raw, "bgra8unorm")) return model_texture_types.WGPUTextureFormat_BGRA8Unorm;
    if (eqIgnoreCase(raw, "bgra8unorm-srgb") or eqIgnoreCase(raw, "bgra8unormsrgb")) return model_texture_types.WGPUTextureFormat_BGRA8UnormSrgb;
    if (eqIgnoreCase(raw, "rgb10a2uint")) return model_texture_types.WGPUTextureFormat_RGB10A2Uint;
    if (eqIgnoreCase(raw, "rgb10a2unorm")) return model_texture_types.WGPUTextureFormat_RGB10A2Unorm;
    if (eqIgnoreCase(raw, "rg11b10ufloat")) return model_texture_types.WGPUTextureFormat_RG11B10Ufloat;
    if (eqIgnoreCase(raw, "rgb9e5ufloat")) return model_texture_types.WGPUTextureFormat_RGB9E5Ufloat;
    if (eqIgnoreCase(raw, "rg32float")) return model_texture_types.WGPUTextureFormat_RG32Float;
    if (eqIgnoreCase(raw, "rg32uint")) return model_texture_types.WGPUTextureFormat_RG32Uint;
    if (eqIgnoreCase(raw, "rg32sint")) return model_texture_types.WGPUTextureFormat_RG32Sint;
    if (eqIgnoreCase(raw, "rgba16uint")) return model_texture_types.WGPUTextureFormat_RGBA16Uint;
    if (eqIgnoreCase(raw, "rgba16sint")) return model_texture_types.WGPUTextureFormat_RGBA16Sint;
    if (eqIgnoreCase(raw, "rgba16float")) return model_texture_types.WGPUTextureFormat_RGBA16Float;
    if (eqIgnoreCase(raw, "rgba32float")) return model_texture_types.WGPUTextureFormat_RGBA32Float;
    if (eqIgnoreCase(raw, "rgba32uint")) return model_texture_types.WGPUTextureFormat_RGBA32Uint;
    if (eqIgnoreCase(raw, "rgba32sint")) return model_texture_types.WGPUTextureFormat_RGBA32Sint;
    if (eqIgnoreCase(raw, "stencil8")) return model_texture_types.WGPUTextureFormat_Stencil8;
    if (eqIgnoreCase(raw, "depth16unorm")) return model_texture_types.WGPUTextureFormat_Depth16Unorm;
    if (eqIgnoreCase(raw, "depth24plus")) return model_texture_types.WGPUTextureFormat_Depth24Plus;
    if (eqIgnoreCase(raw, "depth24plus-stencil8")) return model_texture_types.WGPUTextureFormat_Depth24PlusStencil8;
    if (eqIgnoreCase(raw, "depth32float")) return model_texture_types.WGPUTextureFormat_Depth32Float;
    if (eqIgnoreCase(raw, "depth32float-stencil8")) return model_texture_types.WGPUTextureFormat_Depth32FloatStencil8;
    // BC compressed formats
    if (eqIgnoreCase(raw, "bc1-rgba-unorm")) return compressed_formats.WGPUTextureFormat_BC1RGBAUnorm;
    if (eqIgnoreCase(raw, "bc1-rgba-unorm-srgb")) return compressed_formats.WGPUTextureFormat_BC1RGBAUnormSrgb;
    if (eqIgnoreCase(raw, "bc2-rgba-unorm")) return compressed_formats.WGPUTextureFormat_BC2RGBAUnorm;
    if (eqIgnoreCase(raw, "bc2-rgba-unorm-srgb")) return compressed_formats.WGPUTextureFormat_BC2RGBAUnormSrgb;
    if (eqIgnoreCase(raw, "bc3-rgba-unorm")) return compressed_formats.WGPUTextureFormat_BC3RGBAUnorm;
    if (eqIgnoreCase(raw, "bc3-rgba-unorm-srgb")) return compressed_formats.WGPUTextureFormat_BC3RGBAUnormSrgb;
    if (eqIgnoreCase(raw, "bc4-r-unorm")) return compressed_formats.WGPUTextureFormat_BC4RUnorm;
    if (eqIgnoreCase(raw, "bc4-r-snorm")) return compressed_formats.WGPUTextureFormat_BC4RSnorm;
    if (eqIgnoreCase(raw, "bc5-rg-unorm")) return compressed_formats.WGPUTextureFormat_BC5RGUnorm;
    if (eqIgnoreCase(raw, "bc5-rg-snorm")) return compressed_formats.WGPUTextureFormat_BC5RGSnorm;
    if (eqIgnoreCase(raw, "bc6h-rgb-ufloat")) return compressed_formats.WGPUTextureFormat_BC6HRGBUfloat;
    if (eqIgnoreCase(raw, "bc6h-rgb-float")) return compressed_formats.WGPUTextureFormat_BC6HRGBFloat;
    if (eqIgnoreCase(raw, "bc7-rgba-unorm")) return compressed_formats.WGPUTextureFormat_BC7RGBAUnorm;
    if (eqIgnoreCase(raw, "bc7-rgba-unorm-srgb")) return compressed_formats.WGPUTextureFormat_BC7RGBAUnormSrgb;
    // ASTC compressed formats
    if (eqIgnoreCase(raw, "astc-4x4-unorm")) return compressed_formats.WGPUTextureFormat_ASTC4x4Unorm;
    if (eqIgnoreCase(raw, "astc-4x4-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC4x4UnormSrgb;
    if (eqIgnoreCase(raw, "astc-5x4-unorm")) return compressed_formats.WGPUTextureFormat_ASTC5x4Unorm;
    if (eqIgnoreCase(raw, "astc-5x4-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC5x4UnormSrgb;
    if (eqIgnoreCase(raw, "astc-5x5-unorm")) return compressed_formats.WGPUTextureFormat_ASTC5x5Unorm;
    if (eqIgnoreCase(raw, "astc-5x5-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC5x5UnormSrgb;
    if (eqIgnoreCase(raw, "astc-6x5-unorm")) return compressed_formats.WGPUTextureFormat_ASTC6x5Unorm;
    if (eqIgnoreCase(raw, "astc-6x5-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC6x5UnormSrgb;
    if (eqIgnoreCase(raw, "astc-6x6-unorm")) return compressed_formats.WGPUTextureFormat_ASTC6x6Unorm;
    if (eqIgnoreCase(raw, "astc-6x6-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC6x6UnormSrgb;
    if (eqIgnoreCase(raw, "astc-8x5-unorm")) return compressed_formats.WGPUTextureFormat_ASTC8x5Unorm;
    if (eqIgnoreCase(raw, "astc-8x5-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC8x5UnormSrgb;
    if (eqIgnoreCase(raw, "astc-8x6-unorm")) return compressed_formats.WGPUTextureFormat_ASTC8x6Unorm;
    if (eqIgnoreCase(raw, "astc-8x6-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC8x6UnormSrgb;
    if (eqIgnoreCase(raw, "astc-8x8-unorm")) return compressed_formats.WGPUTextureFormat_ASTC8x8Unorm;
    if (eqIgnoreCase(raw, "astc-8x8-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC8x8UnormSrgb;
    if (eqIgnoreCase(raw, "astc-10x5-unorm")) return compressed_formats.WGPUTextureFormat_ASTC10x5Unorm;
    if (eqIgnoreCase(raw, "astc-10x5-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC10x5UnormSrgb;
    if (eqIgnoreCase(raw, "astc-10x6-unorm")) return compressed_formats.WGPUTextureFormat_ASTC10x6Unorm;
    if (eqIgnoreCase(raw, "astc-10x6-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC10x6UnormSrgb;
    if (eqIgnoreCase(raw, "astc-10x8-unorm")) return compressed_formats.WGPUTextureFormat_ASTC10x8Unorm;
    if (eqIgnoreCase(raw, "astc-10x8-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC10x8UnormSrgb;
    if (eqIgnoreCase(raw, "astc-10x10-unorm")) return compressed_formats.WGPUTextureFormat_ASTC10x10Unorm;
    if (eqIgnoreCase(raw, "astc-10x10-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC10x10UnormSrgb;
    if (eqIgnoreCase(raw, "astc-12x10-unorm")) return compressed_formats.WGPUTextureFormat_ASTC12x10Unorm;
    if (eqIgnoreCase(raw, "astc-12x10-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC12x10UnormSrgb;
    if (eqIgnoreCase(raw, "astc-12x12-unorm")) return compressed_formats.WGPUTextureFormat_ASTC12x12Unorm;
    if (eqIgnoreCase(raw, "astc-12x12-unorm-srgb")) return compressed_formats.WGPUTextureFormat_ASTC12x12UnormSrgb;
    // ETC2/EAC compressed formats
    if (eqIgnoreCase(raw, "etc2-rgb8unorm")) return compressed_formats.WGPUTextureFormat_ETC2RGB8Unorm;
    if (eqIgnoreCase(raw, "etc2-rgb8unorm-srgb")) return compressed_formats.WGPUTextureFormat_ETC2RGB8UnormSrgb;
    if (eqIgnoreCase(raw, "etc2-rgb8a1unorm")) return compressed_formats.WGPUTextureFormat_ETC2RGB8A1Unorm;
    if (eqIgnoreCase(raw, "etc2-rgb8a1unorm-srgb")) return compressed_formats.WGPUTextureFormat_ETC2RGB8A1UnormSrgb;
    if (eqIgnoreCase(raw, "etc2-rgba8unorm")) return compressed_formats.WGPUTextureFormat_ETC2RGBA8Unorm;
    if (eqIgnoreCase(raw, "etc2-rgba8unorm-srgb")) return compressed_formats.WGPUTextureFormat_ETC2RGBA8UnormSrgb;
    if (eqIgnoreCase(raw, "eac-r11unorm")) return compressed_formats.WGPUTextureFormat_EACR11Unorm;
    if (eqIgnoreCase(raw, "eac-r11snorm")) return compressed_formats.WGPUTextureFormat_EACR11Snorm;
    if (eqIgnoreCase(raw, "eac-rg11unorm")) return compressed_formats.WGPUTextureFormat_EACRG11Unorm;
    if (eqIgnoreCase(raw, "eac-rg11snorm")) return compressed_formats.WGPUTextureFormat_EACRG11Snorm;
    if (eqIgnoreCase(raw, "undefined")) return model_texture_types.WGPUTextureFormat_Undefined;
    return std.fmt.parseInt(u32, raw, 10) catch ParseError.InvalidCommandPayload;
}

pub fn parseRenderDrawPipelineMode(raw: ?[]const u8) ParseError!model_render_types.RenderDrawPipelineMode {
    const value = raw orelse return .static;
    if (eqIgnoreCase(value, "static")) return .static;
    if (eqIgnoreCase(value, "redundant")) return .redundant;
    return ParseError.InvalidCommandPayload;
}

pub fn parseRenderDrawBindGroupMode(raw: ?[]const u8) ParseError!model_render_types.RenderDrawBindGroupMode {
    const value = raw orelse return .no_change;
    if (eqIgnoreCase(value, "no-change") or eqIgnoreCase(value, "no_change")) return .no_change;
    if (eqIgnoreCase(value, "redundant")) return .redundant;
    return ParseError.InvalidCommandPayload;
}

pub fn parseRenderIndexFormat(raw: ?[]const u8) ParseError!?model_render_types.RenderIndexFormat {
    const value = raw orelse return null;
    if (eqIgnoreCase(value, "uint16") or eqIgnoreCase(value, "u16")) return .uint16;
    if (eqIgnoreCase(value, "uint32") or eqIgnoreCase(value, "u32")) return .uint32;
    return ParseError.InvalidCommandPayload;
}

fn inferRenderIndexFormat(indices: []const u32) model_render_types.RenderIndexFormat {
    for (indices) |value| {
        if (value > std.math.maxInt(u16)) return .uint32;
    }
    return .uint16;
}

pub fn parseRenderIndexData(
    allocator: std.mem.Allocator,
    raw_indices: []const u32,
    requested_format: ?model_render_types.RenderIndexFormat,
) ParseError!model_render_types.RenderIndexData {
    const chosen_format = requested_format orelse inferRenderIndexFormat(raw_indices);
    return switch (chosen_format) {
        .uint16 => blk: {
            var values = try allocator.alloc(u16, raw_indices.len);
            errdefer allocator.free(values);
            for (raw_indices, 0..) |value, idx| {
                if (value > std.math.maxInt(u16)) return ParseError.InvalidCommandPayload;
                values[idx] = @as(u16, @intCast(value));
            }
            break :blk .{ .uint16 = values };
        },
        .uint32 => blk: {
            const values = try allocator.alloc(u32, raw_indices.len);
            errdefer allocator.free(values);
            @memcpy(values, raw_indices);
            break :blk .{ .uint32 = values };
        },
    };
}
