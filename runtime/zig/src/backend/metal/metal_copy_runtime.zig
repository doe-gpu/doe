const std = @import("std");
const common_timing = @import("../common/timing.zig");
const model_resource_types = @import("../../model_resource_types.zig");
const model_gpu_types = @import("../../model_texture_value_types.zig");
const webgpu = @import("../runtime_types.zig");
const bridge = @import("metal_bridge_decls.zig");
const metal_bridge_blit_encoder_copy_buffer_to_texture = bridge.metal_bridge_blit_encoder_copy_buffer_to_texture;
const metal_bridge_blit_encoder_copy_region = bridge.metal_bridge_blit_encoder_copy_region;
const metal_bridge_blit_encoder_copy_texture_to_buffer = bridge.metal_bridge_blit_encoder_copy_texture_to_buffer;
const metal_bridge_blit_encoder_copy_texture_to_texture = bridge.metal_bridge_blit_encoder_copy_texture_to_texture;
const metal_bridge_begin_blit_encoding = bridge.metal_bridge_begin_blit_encoding;
const metal_bridge_cmd_buf_blit_encoder = bridge.metal_bridge_cmd_buf_blit_encoder;
const metal_bridge_end_blit_encoding = bridge.metal_bridge_end_blit_encoding;
const metal_bridge_create_command_buffer = bridge.metal_bridge_create_command_buffer;
const metal_bridge_device_new_buffer_shared = bridge.metal_bridge_device_new_buffer_shared;
const metal_bridge_device_new_texture = bridge.metal_bridge_device_new_texture;
const metal_bridge_release = bridge.metal_bridge_release;
const metal_bridge_render_encoder_end = bridge.metal_bridge_render_encoder_end;

pub const CopyMetrics = struct {
    setup_ns: u64,
    encode_ns: u64,
    submit_wait_ns: u64,
    gpu_elapsed_ns: u64 = 0,
    gpu_timestamps_attempted: bool = false,
    gpu_timestamps_valid: bool = false,
};

pub fn execute_copy(self: anytype, cmd: model_resource_types.CopyCommand, queue_sync_mode: webgpu.QueueSyncMode) !CopyMetrics {
    const setup_start = common_timing.now_ns();
    const src_buffer = if (cmd.direction == .buffer_to_buffer or cmd.direction == .buffer_to_texture)
        try ensure_buffer(self, cmd.src.handle, required_buffer_size(cmd.bytes, cmd.src.offset))
    else
        null;
    const dst_buffer = if (cmd.direction == .buffer_to_buffer or cmd.direction == .texture_to_buffer)
        try ensure_buffer(self, cmd.dst.handle, required_buffer_size(cmd.bytes, cmd.dst.offset))
    else
        null;
    const src_texture = if (cmd.direction == .texture_to_buffer or cmd.direction == .texture_to_texture)
        try ensure_texture(self, cmd.src, model_gpu_types.WGPUTextureUsage_CopySrc)
    else
        null;
    const dst_texture = if (cmd.direction == .buffer_to_texture or cmd.direction == .texture_to_texture)
        try ensure_texture(self, cmd.dst, model_gpu_types.WGPUTextureUsage_CopyDst)
    else
        null;
    const setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);

    try ensure_blit_encoder(self);

    const encode_start = common_timing.now_ns();
    switch (cmd.direction) {
        .buffer_to_buffer => {
            metal_bridge_blit_encoder_copy_region(
                self.streaming_blit_encoder,
                src_buffer,
                cmd.src.offset,
                dst_buffer,
                cmd.dst.offset,
                cmd.bytes,
            );
        },
        .buffer_to_texture => metal_bridge_blit_encoder_copy_buffer_to_texture(
            self.streaming_blit_encoder,
            src_buffer,
            cmd.src.offset,
            normalize_copy_pitch(cmd.src.bytes_per_row, cmd.dst.width, 4),
            normalize_copy_rows(cmd.src.rows_per_image, cmd.dst.height),
            dst_texture,
            cmd.dst.mip_level,
            cmd.dst.width,
            cmd.dst.height,
            normalize_copy_depth(cmd.dst.depth_or_array_layers),
        ),
        .texture_to_buffer => metal_bridge_blit_encoder_copy_texture_to_buffer(
            self.streaming_blit_encoder,
            src_texture,
            cmd.src.mip_level,
            dst_buffer,
            cmd.dst.offset,
            normalize_copy_pitch(cmd.dst.bytes_per_row, cmd.src.width, 4),
            normalize_copy_rows(cmd.dst.rows_per_image, cmd.src.height),
            cmd.src.width,
            cmd.src.height,
            normalize_copy_depth(cmd.src.depth_or_array_layers),
        ),
        .texture_to_texture => {
            if (cmd.uses_temporary_buffer) {
                // Quirk workaround: stage texture-to-texture through a temporary
                // buffer to avoid driver bugs on certain GPU/driver combinations.
                const staging_size = alignedStagingSize(cmd);
                const staging_buf = metal_bridge_device_new_buffer_shared(self.device, staging_size) orelse return error.InvalidState;
                defer metal_bridge_release(staging_buf);

                const width = if (cmd.src.width > 0) cmd.src.width else 1;
                const height = if (cmd.src.height > 0) cmd.src.height else 1;
                const depth = normalize_copy_depth(cmd.src.depth_or_array_layers);
                const bpr = normalize_copy_pitch(cmd.src.bytes_per_row, width, 4);
                const rpi = normalize_copy_rows(cmd.src.rows_per_image, height);

                metal_bridge_blit_encoder_copy_texture_to_buffer(
                    self.streaming_blit_encoder,
                    src_texture,
                    cmd.src.mip_level,
                    staging_buf,
                    0,
                    bpr,
                    rpi,
                    width,
                    height,
                    depth,
                );
                metal_bridge_blit_encoder_copy_buffer_to_texture(
                    self.streaming_blit_encoder,
                    staging_buf,
                    0,
                    bpr,
                    rpi,
                    dst_texture,
                    cmd.dst.mip_level,
                    if (cmd.dst.width > 0) cmd.dst.width else width,
                    if (cmd.dst.height > 0) cmd.dst.height else height,
                    depth,
                );
            } else {
                metal_bridge_blit_encoder_copy_texture_to_texture(
                    self.streaming_blit_encoder,
                    src_texture,
                    cmd.src.mip_level,
                    dst_texture,
                    cmd.dst.mip_level,
                    cmd.src.width,
                    cmd.src.height,
                    normalize_copy_depth(cmd.src.depth_or_array_layers),
                );
            }
        },
    }
    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

    self.has_deferred_submissions = true;
    self.streaming_has_copy = true;
    if (queue_sync_mode == .deferred) {
        return .{ .setup_ns = setup_ns, .encode_ns = encode_ns, .submit_wait_ns = 0 };
    }
    const flush = try self.flush_queue_timed();
    return .{
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = flush.submit_wait_ns,
        .gpu_elapsed_ns = flush.gpu_elapsed_ns,
        .gpu_timestamps_attempted = flush.gpu_timestamps_attempted,
        .gpu_timestamps_valid = flush.gpu_timestamps_valid,
    };
}

fn ensure_buffer(self: anytype, handle: u64, size: u64) !?*anyopaque {
    if (self.compute_buffers.get(handle)) |buf| return buf;
    const buffer = metal_bridge_device_new_buffer_shared(self.device, @intCast(size)) orelse return error.InvalidState;
    try self.compute_buffers.put(self.allocator, handle, buffer);
    return buffer;
}

fn ensure_texture(self: anytype, resource: model_resource_types.CopyTextureResource, required_usage: model_gpu_types.WGPUFlags) !?*anyopaque {
    if (self.textures.get(resource.handle)) |tex| return tex;
    const usage = if (resource.usage != 0) resource.usage else required_usage;
    const mip_levels: u32 = if (resource.mip_level > 0) resource.mip_level + 1 else 1;
    const texture = metal_bridge_device_new_texture(
        self.device,
        max_dim(resource.width),
        max_dim(resource.height),
        resource.depth_or_array_layers,
        mip_levels,
        resource.sample_count,
        resource.format,
        @intCast(usage),
        resource.dimension,
    ) orelse return error.InvalidState;
    try self.textures.put(self.allocator, resource.handle, texture);
    return texture;
}

fn ensure_blit_encoder(self: anytype) !void {
    if (self.streaming_compute_encoder) |enc| {
        bridge.metal_bridge_end_compute_encoding(enc);
        self.streaming_compute_encoder = null;
    }
    if (self.streaming_render_encoder) |enc| {
        metal_bridge_render_encoder_end(enc);
        metal_bridge_release(enc);
        self.streaming_render_encoder = null;
    }
    if (self.streaming_blit_encoder != null) return;
    if (self.streaming_cmd_buf == null) {
        self.streaming_cmd_buf = metal_bridge_create_command_buffer(self.queue) orelse return error.InvalidState;
    }
    self.streaming_blit_encoder = metal_bridge_cmd_buf_blit_encoder(self.streaming_cmd_buf) orelse return error.InvalidState;
}

fn required_buffer_size(bytes: usize, offset: u64) u64 {
    return @as(u64, @intCast(bytes)) + offset;
}

fn max_dim(value: u32) u32 {
    return if (value == 0) 1 else value;
}

fn normalize_copy_pitch(value: u32, width: u32, bytes_per_pixel: u32) u32 {
    return if (value == 0) width * bytes_per_pixel else value;
}

fn normalize_copy_rows(value: u32, height: u32) u32 {
    return if (value == 0) height else value;
}

fn normalize_copy_depth(value: u32) u32 {
    return if (value == 0) 1 else value;
}

fn alignedStagingSize(cmd: model_resource_types.CopyCommand) u64 {
    const raw: u64 = if (cmd.bytes > 0) @intCast(cmd.bytes) else blk: {
        const w: u64 = if (cmd.src.width > 0) cmd.src.width else 1;
        const h: u64 = if (cmd.src.height > 0) cmd.src.height else 1;
        const d: u64 = if (cmd.src.depth_or_array_layers > 0) cmd.src.depth_or_array_layers else 1;
        break :blk w * h * d * 4;
    };
    const a: u64 = if (cmd.temporary_buffer_alignment > 1) cmd.temporary_buffer_alignment else 1;
    return (raw + a - 1) / a * a;
}
