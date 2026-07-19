const std = @import("std");
const log = std.log.scoped(.render_runtime);
const model_gpu_types = @import("../../../contracts/model/model_texture_value_types.zig");
const model_render_types = @import("../../../contracts/model/model_render_types.zig");
const runtime_types = @import("../../../backend/runtime_types.zig");
const render_commands = @import("../../render/wgpu_render_commands.zig");
const webgpu = @import("../../../backend/webgpu_backend.zig");
const common = @import("../common.zig");

pub const RenderRuntimeError = error{
    RuntimeUnavailable,
    UnsupportedTextureFormat,
};

pub const RenderExecutionConfig = struct {
    target_width: u32,
    target_height: u32,
    target_format: []const u8,
    draw_count: u32,
    vertex_count: u32 = 3,
    instance_count: u32 = 1,
    target_handle: u64,
    pipeline_mode: model_render_types.RenderDrawPipelineMode = .static,
    bind_group_mode: model_render_types.RenderDrawBindGroupMode = .no_change,
    encode_mode: model_render_types.RenderDrawEncodeMode = .render_bundle,
    uses_temporary_render_texture: bool = false,
    dynamic_offset_slot: ?u32 = null,
};

pub fn textureFormatFromString(value: []const u8) RenderRuntimeError!model_gpu_types.WGPUTextureFormat {
    if (std.mem.eql(u8, value, "rgba8unorm")) return model_gpu_types.WGPUTextureFormat_RGBA8Unorm;
    if (std.mem.eql(u8, value, "rgba8unorm-srgb")) return model_gpu_types.WGPUTextureFormat_RGBA8UnormSrgb;
    if (std.mem.eql(u8, value, "bgra8unorm")) return model_gpu_types.WGPUTextureFormat_BGRA8Unorm;
    return RenderRuntimeError.UnsupportedTextureFormat;
}

pub fn execute(allocator: std.mem.Allocator, config: RenderExecutionConfig) !runtime_types.NativeExecutionResult {
    common.ensureLocalLibrarySearchPath(allocator) catch |err| {
        log.warn("library search path: {s}", .{@errorName(err)});
    };
    const profile = common.hostProfile() catch return RenderRuntimeError.RuntimeUnavailable;

    var backend = webgpu.WebGPUBackend.init(allocator, profile, null) catch {
        return RenderRuntimeError.RuntimeUnavailable;
    };
    defer backend.deinit();

    var dynamic_offsets_storage = [_]u32{0};
    const dynamic_offsets: ?[]const u32 = if (config.dynamic_offset_slot) |slot| blk: {
        dynamic_offsets_storage[0] = slot * 256;
        break :blk dynamic_offsets_storage[0..];
    } else null;

    const command = model_render_types.RenderDrawCommand{
        .draw_count = config.draw_count,
        .vertex_count = config.vertex_count,
        .instance_count = config.instance_count,
        .target_handle = config.target_handle,
        .target_width = config.target_width,
        .target_height = config.target_height,
        .target_format = try textureFormatFromString(config.target_format),
        .uses_temporary_render_texture = config.uses_temporary_render_texture,
        .pipeline_mode = config.pipeline_mode,
        .bind_group_mode = config.bind_group_mode,
        .encode_mode = config.encode_mode,
        .bind_group_dynamic_offsets = dynamic_offsets,
    };
    return try render_commands.executeRenderDraw(&backend, command);
}
