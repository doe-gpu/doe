const std = @import("std");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const model_texture_types = @import("../../contracts/model/model_texture_types.zig");
const proc_types = @import("../abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const abi_execution = @import("../abi/wgpu_execution_types.zig");
const loader = @import("../abi/wgpu_loader.zig");
const resources = @import("wgpu_resources.zig");
const texture_procs_mod = @import("../abi/procs/wgpu_texture_procs.zig");

pub fn executeTextureWrite(self: anytype, texture_cmd: model_texture_types.TextureWriteCommand) !abi_execution.NativeExecutionResult {
    const texture_procs = texture_procs_mod.loadTextureProcs(self.core.dyn_lib) orelse return error.TextureProcUnavailable;
    const required_usage = abi_base.WGPUTextureUsage_CopyDst;
    if (texture_cmd.data.len == 0) {
        _ = try resources.getOrCreateTextureInitialized(self, texture_cmd.texture, required_usage);
        return .{ .status = .ok, .status_message = "texture created and zero initialized" };
    }

    const texture = try resources.getOrCreateTexture(self, texture_cmd.texture, required_usage);

    const bytes_per_texel = try textureBytesPerTexel(texture_cmd.texture.format);
    const width_u64 = @as(u64, texture_cmd.texture.width);
    const height_u64 = @as(u64, texture_cmd.texture.height);
    const depth_u64 = @as(u64, texture_cmd.texture.depth_or_array_layers);
    const min_bytes_per_row = std.math.mul(u64, width_u64, bytes_per_texel) catch return error.InvalidTextureWriteLayout;
    const bytes_per_row = if (texture_cmd.texture.bytes_per_row == 0)
        min_bytes_per_row
    else
        @as(u64, texture_cmd.texture.bytes_per_row);
    if (bytes_per_row < min_bytes_per_row) return error.InvalidTextureWriteLayout;
    const rows_per_image = if (texture_cmd.texture.rows_per_image == 0)
        height_u64
    else
        @as(u64, texture_cmd.texture.rows_per_image);
    if (rows_per_image < height_u64) return error.InvalidTextureWriteLayout;
    const copy_bytes = std.math.mul(u64, bytes_per_row, rows_per_image) catch return error.InvalidTextureWriteLayout;
    const total_bytes = std.math.mul(u64, copy_bytes, depth_u64) catch return error.InvalidTextureWriteLayout;
    const needed = std.math.add(u64, texture_cmd.texture.offset, total_bytes) catch return error.InvalidTextureWriteLayout;
    if (needed > texture_cmd.data.len) return error.InvalidTextureWriteLayout;

    texture_procs.queue_write_texture(
        self.core.queue.?,
        &abi_descriptor.WGPUTexelCopyTextureInfo{
            .texture = texture,
            .mipLevel = texture_cmd.texture.mip_level,
            .origin = .{ .x = 0, .y = 0, .z = 0 },
            .aspect = loader.normalizeTextureAspect(texture_cmd.texture.aspect),
        },
        texture_cmd.data.ptr,
        texture_cmd.data.len,
        &abi_descriptor.WGPUTexelCopyBufferLayout{
            .offset = texture_cmd.texture.offset,
            .bytesPerRow = @as(u32, @intCast(bytes_per_row)),
            .rowsPerImage = @as(u32, @intCast(rows_per_image)),
        },
        &abi_descriptor.WGPUExtent3D{
            .width = texture_cmd.texture.width,
            .height = texture_cmd.texture.height,
            .depthOrArrayLayers = texture_cmd.texture.depth_or_array_layers,
        },
    );
    return .{ .status = .ok, .status_message = "texture write submitted" };
}

pub fn executeTextureQuery(self: anytype, texture_cmd: model_texture_types.TextureQueryCommand) !abi_execution.NativeExecutionResult {
    const texture_procs = texture_procs_mod.loadTextureProcs(self.core.dyn_lib) orelse return error.TextureProcUnavailable;
    if (self.core.textures.getPtr(texture_cmd.handle)) |record| {
        const info = texture_procs_mod.queryTextureInfo(texture_procs, record.texture);
        if (info.width == 0 or info.height == 0 or info.depth_or_array_layers == 0) {
            return .{ .status = .@"error", .status_message = "texture query returned invalid dimensions" };
        }
        if (texture_cmd.expected_width) |expected| {
            if (info.width != expected) return .{ .status = .unsupported, .status_message = "texture query width mismatch" };
        }
        if (texture_cmd.expected_height) |expected| {
            if (info.height != expected) return .{ .status = .unsupported, .status_message = "texture query height mismatch" };
        }
        if (texture_cmd.expected_depth_or_array_layers) |expected| {
            if (info.depth_or_array_layers != expected) return .{ .status = .unsupported, .status_message = "texture query depth mismatch" };
        }
        if (texture_cmd.expected_format) |expected| {
            if (info.format != expected) return .{ .status = .unsupported, .status_message = "texture query format mismatch" };
        }
        if (texture_cmd.expected_dimension) |expected| {
            if (info.dimension != expected) return .{ .status = .unsupported, .status_message = "texture query dimension mismatch" };
        }
        if (texture_cmd.expected_view_dimension) |expected| {
            if (info.view_dimension != expected) return .{ .status = .unsupported, .status_message = "texture query view-dimension mismatch" };
        }
        if (texture_cmd.expected_sample_count) |expected| {
            if (info.sample_count != expected) return .{ .status = .unsupported, .status_message = "texture query sample-count mismatch" };
        }
        if (texture_cmd.expected_usage) |expected| {
            if ((info.usage & expected) != expected) return .{ .status = .unsupported, .status_message = "texture query usage mismatch" };
        }
        record.width = info.width;
        record.height = info.height;
        record.depth_or_array_layers = info.depth_or_array_layers;
        record.format = info.format;
        record.dimension = info.dimension;
        record.sample_count = info.sample_count;
        record.usage = info.usage;
        return .{ .status = .ok, .status_message = "texture query completed" };
    }
    return .{ .status = .unsupported, .status_message = "texture handle not found" };
}

pub fn executeTextureDestroy(self: anytype, texture_cmd: model_texture_types.TextureDestroyCommand) !abi_execution.NativeExecutionResult {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const texture_procs = texture_procs_mod.loadTextureProcs(self.core.dyn_lib) orelse return error.TextureProcUnavailable;
    const removed = self.core.textures.fetchRemove(texture_cmd.handle) orelse {
        return .{ .status = .unsupported, .status_message = "texture handle not found" };
    };
    self.releaseFullTextureViewsForTexture(removed.value.texture);
    texture_procs.texture_destroy(removed.value.texture);
    procs.wgpuTextureRelease(removed.value.texture);
    return .{ .status = .ok, .status_message = "texture destroyed" };
}

fn textureBytesPerTexel(format: abi_base.WGPUTextureFormat) !u64 {
    return switch (format) {
        model_gpu_types.WGPUTextureFormat_R8Unorm,
        model_gpu_types.WGPUTextureFormat_R8Snorm,
        model_gpu_types.WGPUTextureFormat_R8Uint,
        model_gpu_types.WGPUTextureFormat_R8Sint,
        => 1,
        model_gpu_types.WGPUTextureFormat_R16Unorm,
        model_gpu_types.WGPUTextureFormat_R16Snorm,
        model_gpu_types.WGPUTextureFormat_R16Uint,
        model_gpu_types.WGPUTextureFormat_R16Sint,
        model_gpu_types.WGPUTextureFormat_R16Float,
        model_gpu_types.WGPUTextureFormat_RG8Unorm,
        model_gpu_types.WGPUTextureFormat_RG8Snorm,
        model_gpu_types.WGPUTextureFormat_RG8Uint,
        model_gpu_types.WGPUTextureFormat_RG8Sint,
        => 2,
        model_gpu_types.WGPUTextureFormat_R32Float,
        model_gpu_types.WGPUTextureFormat_R32Uint,
        model_gpu_types.WGPUTextureFormat_R32Sint,
        model_gpu_types.WGPUTextureFormat_RG16Unorm,
        model_gpu_types.WGPUTextureFormat_RG16Snorm,
        model_gpu_types.WGPUTextureFormat_RG16Uint,
        model_gpu_types.WGPUTextureFormat_RG16Sint,
        model_gpu_types.WGPUTextureFormat_RG16Float,
        model_gpu_types.WGPUTextureFormat_RGBA8Unorm,
        model_gpu_types.WGPUTextureFormat_RGBA8UnormSrgb,
        model_gpu_types.WGPUTextureFormat_RGBA8Snorm,
        model_gpu_types.WGPUTextureFormat_RGBA8Uint,
        model_gpu_types.WGPUTextureFormat_RGBA8Sint,
        model_gpu_types.WGPUTextureFormat_BGRA8Unorm,
        model_gpu_types.WGPUTextureFormat_BGRA8UnormSrgb,
        model_gpu_types.WGPUTextureFormat_Depth24Plus,
        model_gpu_types.WGPUTextureFormat_Depth24PlusStencil8,
        model_gpu_types.WGPUTextureFormat_Depth32Float,
        model_gpu_types.WGPUTextureFormat_Depth32FloatStencil8,
        => 4,
        else => error.UnsupportedTextureFormat,
    };
}
