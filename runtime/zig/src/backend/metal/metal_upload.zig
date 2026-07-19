// metal_upload.zig — Upload path: staging buffer management and upload_bytes.
// Sharded from metal_native_runtime.zig to stay under the line-limit policy.

const std = @import("std");
const webgpu = @import("../runtime_types.zig");
const bridge = @import("metal_bridge_decls.zig");
const metal_bridge_begin_blit_encoding = bridge.metal_bridge_begin_blit_encoding;
const metal_bridge_blit_encoder_copy = bridge.metal_bridge_blit_encoder_copy;
const metal_bridge_blit_encoder_copy_region = bridge.metal_bridge_blit_encoder_copy_region;
const metal_bridge_buffer_contents = bridge.metal_bridge_buffer_contents;
const metal_bridge_cmd_buf_blit_encoder = bridge.metal_bridge_cmd_buf_blit_encoder;
const metal_bridge_device_new_buffer_private = bridge.metal_bridge_device_new_buffer_private;
const metal_bridge_device_new_buffer_shared = bridge.metal_bridge_device_new_buffer_shared;
const metal_bridge_end_blit_encoding = bridge.metal_bridge_end_blit_encoding;
const metal_bridge_end_compute_encoding = bridge.metal_bridge_end_compute_encoding;
const metal_bridge_release = bridge.metal_bridge_release;
const metal_bridge_render_encoder_end = bridge.metal_bridge_render_encoder_end;

const metal_buffer_pool = @import("metal_buffer_pool.zig");
const metal_runtime_limits = @import("metal_runtime_limits.zig");

const SMALL_UPLOAD_CAPACITY = metal_runtime_limits.SMALL_UPLOAD_CAPACITY;

pub fn upload_bytes(self: anytype, bytes: u64, mode: webgpu.UploadBufferUsageMode) !void {
    if (bytes == 0) return error.InvalidArgument;
    const len: usize = @intCast(bytes);
    const use_small_staging = len <= SMALL_UPLOAD_CAPACITY and
        self.staging_src != null and self.staging_dst != null and self.staging_src_ptr != null;
    const pooled_src = if (use_small_staging) null else metal_buffer_pool.pool_pop(&self.shared_pool, len);
    const src = if (use_small_staging)
        self.staging_src.?
    else
        pooled_src orelse
            (metal_bridge_device_new_buffer_shared(self.device, len) orelse return error.InvalidState);
    if (use_small_staging) {
        if (!self.staging_src_zeroed) {
            @memset(self.staging_src_ptr.?[0..len], 0);
            self.staging_src_zeroed = true;
        }
    } else {
        const raw = metal_bridge_buffer_contents(src) orelse return error.InvalidState;
        @memset(@as([*]u8, @ptrCast(raw))[0..len], 0);
    }

    if (mode == .copy_dst_copy_src) {
        if (!use_small_staging) {
            pool_push_or_release(&self.shared_pool, self.allocator, len, src);
        }
        self.streaming_max_upload_bytes = @max(self.streaming_max_upload_bytes, len);
        self.has_deferred_submissions = true;
        return;
    }

    const dst = if (use_small_staging)
        self.staging_dst.?
    else
        metal_buffer_pool.pool_pop(&self.private_pool, len) orelse
            (metal_bridge_device_new_buffer_private(self.device, len) orelse return error.InvalidState);

    if (self.streaming_compute_encoder) |enc| {
        metal_bridge_end_compute_encoding(enc);
        self.streaming_compute_encoder = null;
    }
    if (self.streaming_render_encoder) |enc| {
        metal_bridge_render_encoder_end(enc);
        metal_bridge_release(enc);
        self.streaming_render_encoder = null;
    }
    if (self.streaming_blit_encoder == null) {
        if (self.streaming_cmd_buf == null) {
            var encoder: ?*anyopaque = null;
            self.streaming_cmd_buf = metal_bridge_begin_blit_encoding(self.queue, &encoder) orelse return error.InvalidState;
            self.streaming_blit_encoder = encoder;
        } else {
            self.streaming_blit_encoder = metal_bridge_cmd_buf_blit_encoder(self.streaming_cmd_buf) orelse return error.InvalidState;
        }
    }
    if (!use_small_staging) {
        try self.streaming_uploads.append(self.allocator, .{
            .src_buffer = src,
            .dst_buffer = dst,
            .byte_count = len,
        });
    }
    metal_bridge_blit_encoder_copy(self.streaming_blit_encoder, src, dst, len);
    self.streaming_max_upload_bytes = @max(self.streaming_max_upload_bytes, len);
    self.has_deferred_submissions = true;
}

pub fn stage_buffer_write_bytes(
    self: anytype,
    dst_buffer: ?*anyopaque,
    dst_offset: u64,
    data_bytes: []const u8,
) !void {
    if (data_bytes.len == 0) return error.InvalidArgument;
    const len = data_bytes.len;
    const use_small_staging = len <= SMALL_UPLOAD_CAPACITY and
        self.staging_src != null and self.staging_src_ptr != null;
    const pooled_src = if (use_small_staging) null else metal_buffer_pool.pool_pop(&self.shared_pool, len);
    const src = if (use_small_staging)
        self.staging_src.?
    else
        pooled_src orelse
            (metal_bridge_device_new_buffer_shared(self.device, len) orelse return error.InvalidState);

    const src_ptr: [*]u8 = if (use_small_staging)
        self.staging_src_ptr.?
    else blk: {
        const raw = metal_bridge_buffer_contents(src) orelse return error.InvalidState;
        break :blk @as([*]u8, @ptrCast(raw));
    };
    @memcpy(src_ptr[0..len], data_bytes);

    if (self.streaming_compute_encoder) |enc| {
        metal_bridge_end_compute_encoding(enc);
        self.streaming_compute_encoder = null;
    }
    if (self.streaming_render_encoder) |enc| {
        metal_bridge_render_encoder_end(enc);
        metal_bridge_release(enc);
        self.streaming_render_encoder = null;
    }
    if (self.streaming_blit_encoder == null) {
        if (self.streaming_cmd_buf == null) {
            var encoder: ?*anyopaque = null;
            self.streaming_cmd_buf = metal_bridge_begin_blit_encoding(self.queue, &encoder) orelse return error.InvalidState;
            self.streaming_blit_encoder = encoder;
        } else {
            self.streaming_blit_encoder = metal_bridge_cmd_buf_blit_encoder(self.streaming_cmd_buf) orelse return error.InvalidState;
        }
    }

    if (!use_small_staging) {
        try self.streaming_uploads.append(self.allocator, .{
            .src_buffer = src,
            .dst_buffer = null,
            .byte_count = len,
        });
    }
    metal_bridge_blit_encoder_copy_region(self.streaming_blit_encoder, src, 0, dst_buffer, dst_offset, len);
    self.streaming_max_upload_bytes = @max(self.streaming_max_upload_bytes, len);
    self.streaming_has_copy = true;
    self.has_deferred_submissions = true;
}

pub fn prewarm_upload_path(self: anytype, max_upload_bytes: u64, mode: webgpu.UploadBufferUsageMode) !void {
    if (max_upload_bytes == 0) return;
    if (self.staging_src == null and max_upload_bytes <= SMALL_UPLOAD_CAPACITY) {
        const cap = SMALL_UPLOAD_CAPACITY;
        self.staging_src = metal_bridge_device_new_buffer_shared(self.device, cap);
        self.staging_dst = metal_bridge_device_new_buffer_private(self.device, cap);
        if (self.staging_src) |s| {
            self.staging_src_ptr = @ptrCast(metal_bridge_buffer_contents(s));
        }
        self.staging_src_zeroed = false;
    }
    try upload_bytes(self, max_upload_bytes, mode);
    _ = try self.flush_queue();
}

fn pool_push_or_release(pool: *metal_buffer_pool.BufferPool, allocator: std.mem.Allocator, size: usize, buf: ?*anyopaque) void {
    metal_buffer_pool.pool_push_or_release(pool, allocator, size, buf);
}
