const std = @import("std");
const model_gpu_types = @import("../../../contracts/model/model_texture_value_types.zig");
const model_texture_types = @import("../../../contracts/model/model_texture_types.zig");
const common_timing = @import("../../common/timing.zig");
const dc = @import("../d3d12_constants.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

const MAX_TEXTURE_WRITE_BYTES: usize = 64 * 1024 * 1024;

pub const TextureEntry = struct {
    handle: u64,
    resource: ?*anyopaque,
    width: u32,
    height: u32,
    depth_or_array_layers: u32 = 1,
    format: u32,
    usage: u64 = 0,
    dimension: u32 = model_gpu_types.WGPUTextureDimension_2D,
    sample_count: u32 = 1,
    mip_levels: u32 = 1,
};

pub const TextureMap = std.AutoHashMapUnmanaged(u64, TextureEntry);

pub fn texture_write(
    device: ?*anyopaque,
    queue: ?*anyopaque,
    texture_map: *TextureMap,
    allocator: std.mem.Allocator,
    cmd: model_texture_types.TextureWriteCommand,
) !u64 {
    const tex_res = &cmd.texture;
    const data = cmd.data;
    if (data.len == 0) return error.InvalidArgument;
    if (data.len > MAX_TEXTURE_WRITE_BYTES) return error.UnsupportedFeature;

    const width = if (tex_res.width > 0) tex_res.width else 1;
    const height = if (tex_res.height > 0) tex_res.height else 1;
    const depth_or_layers = if (tex_res.depth_or_array_layers > 0) tex_res.depth_or_array_layers else 1;
    const format: u32 = if (tex_res.format != model_gpu_types.WGPUTextureFormat_Undefined) tex_res.format else model_gpu_types.WGPUTextureFormat_RGBA8Unorm;
    const usage: u32 = @truncate(tex_res.usage);
    const rows_per_image = if (tex_res.rows_per_image > 0) tex_res.rows_per_image else height;

    if (tex_res.sample_count > 1) return error.UnsupportedFeature;
    if (tex_res.dimension == model_gpu_types.WGPUTextureDimension_1D) return error.UnsupportedFeature;
    if (tex_res.dimension == model_gpu_types.WGPUTextureDimension_3D and rows_per_image != height) return error.UnsupportedFeature;

    const encode_start = common_timing.now_ns();

    var entry = texture_map.get(tex_res.handle);
    if (entry == null) {
        const tex_handle = switch (tex_res.dimension) {
            model_gpu_types.WGPUTextureDimension_3D => bridge.c.d3d12_bridge_device_create_texture_3d(
                device,
                width,
                height,
                depth_or_layers,
                1,
                format,
                usage,
            ),
            else => bridge.c.d3d12_bridge_device_create_texture_2d_layered(
                device,
                width,
                height,
                depth_or_layers,
                1,
                tex_res.sample_count,
                format,
                usage,
            ),
        } orelse return error.InvalidState;
        const new_entry = TextureEntry{
            .handle = tex_res.handle,
            .resource = tex_handle,
            .width = width,
            .height = height,
            .depth_or_array_layers = depth_or_layers,
            .format = format,
            .usage = tex_res.usage,
            .dimension = if (tex_res.dimension != model_gpu_types.WGPUTextureDimension_Undefined) tex_res.dimension else model_gpu_types.WGPUTextureDimension_2D,
            .sample_count = if (tex_res.sample_count > 0) tex_res.sample_count else 1,
            .mip_levels = if (tex_res.mip_level > 0) tex_res.mip_level + 1 else 1,
        };
        texture_map.put(allocator, tex_res.handle, new_entry) catch {
            bridge.c.d3d12_bridge_release(tex_handle);
            return error.InvalidState;
        };
        entry = new_entry;
    }

    const staging = bridge.c.d3d12_bridge_device_create_buffer(device, data.len, dc.HEAP_TYPE_UPLOAD) orelse return error.InvalidState;
    defer bridge.c.d3d12_bridge_release(staging);

    const cmd_alloc = bridge.c.d3d12_bridge_device_create_command_allocator(device) orelse return error.InvalidState;
    defer bridge.c.d3d12_bridge_release(cmd_alloc);

    const cmd_list = bridge.c.d3d12_bridge_device_create_command_list(device, cmd_alloc) orelse return error.InvalidState;
    defer bridge.c.d3d12_bridge_release(cmd_list);

    const bytes_per_row = if (tex_res.bytes_per_row > 0) tex_res.bytes_per_row else @as(u32, @intCast(data.len / @as(usize, rows_per_image * depth_or_layers)));

    if (tex_res.dimension == model_gpu_types.WGPUTextureDimension_3D) {
        bridge.c.d3d12_bridge_command_list_copy_texture_region_subresource(
            cmd_list,
            entry.?.resource,
            tex_res.mip_level,
            staging,
            0,
            width,
            height,
            depth_or_layers,
            bytes_per_row,
            format,
        );
    } else if (depth_or_layers > 1) {
        const slice_stride = @as(u64, bytes_per_row) * rows_per_image;
        var layer_index: u32 = 0;
        while (layer_index < depth_or_layers) : (layer_index += 1) {
            bridge.c.d3d12_bridge_command_list_copy_texture_region_subresource(
                cmd_list,
                entry.?.resource,
                layer_index,
                staging,
                slice_stride * layer_index,
                width,
                height,
                1,
                bytes_per_row,
                format,
            );
        }
    } else {
        bridge.c.d3d12_bridge_command_list_copy_texture_region(cmd_list, entry.?.resource, staging, 0, width, height, bytes_per_row, format);
    }
    bridge.c.d3d12_bridge_command_list_resource_barrier_transition(cmd_list, entry.?.resource, dc.RESOURCE_STATE_COPY_DEST, dc.RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    bridge.c.d3d12_bridge_command_list_close(cmd_list);
    bridge.c.d3d12_bridge_queue_execute_command_list(queue, cmd_list);

    return common_timing.ns_delta(common_timing.now_ns(), encode_start);
}

pub fn texture_query(
    texture_map: *const TextureMap,
    cmd: model_texture_types.TextureQueryCommand,
) !u64 {
    const encode_start = common_timing.now_ns();

    const entry = texture_map.get(cmd.handle) orelse return error.InvalidArgument;

    if (cmd.expected_width) |ew| {
        if (ew != entry.width) return error.InvalidArgument;
    }
    if (cmd.expected_height) |eh| {
        if (eh != entry.height) return error.InvalidArgument;
    }
    if (cmd.expected_depth_or_array_layers) |ed| {
        if (ed != entry.depth_or_array_layers) return error.InvalidArgument;
    }
    if (cmd.expected_format) |ef| {
        if (ef != entry.format) return error.InvalidArgument;
    }
    if (cmd.expected_sample_count) |esc| {
        if (esc != entry.sample_count) return error.InvalidArgument;
    }

    return common_timing.ns_delta(common_timing.now_ns(), encode_start);
}

pub fn texture_destroy(
    texture_map: *TextureMap,
    cmd: model_texture_types.TextureDestroyCommand,
) !u64 {
    const encode_start = common_timing.now_ns();

    if (texture_map.fetchRemove(cmd.handle)) |kv| {
        if (kv.value.resource) |res| {
            bridge.c.d3d12_bridge_release(res);
        }
    }

    return common_timing.ns_delta(common_timing.now_ns(), encode_start);
}

pub fn release_all(texture_map: *TextureMap) void {
    var it = texture_map.valueIterator();
    while (it.next()) |entry| {
        if (entry.resource) |res| bridge.c.d3d12_bridge_release(res);
    }
    texture_map.clearAndFree(std.heap.page_allocator);
}
