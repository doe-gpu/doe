const std = @import("std");
const common_timing = @import("../common/timing.zig");
const webgpu = @import("../runtime_types.zig");
const metal_buffer_pool = @import("metal_buffer_pool.zig");
const metal_runtime_limits = @import("metal_runtime_limits.zig");
const metal_upload = @import("metal_upload.zig");
const bridge = @import("metal_bridge_decls.zig");

pub const FlushResult = struct {
    submit_wait_ns: u64 = 0,
    gpu_elapsed_ns: u64 = 0,
    gpu_timestamps_attempted: bool = false,
    gpu_timestamps_valid: bool = false,
};

pub fn flush_queue(self: anytype) !u64 {
    const result = try flush_queue_timed(self);
    return result.submit_wait_ns;
}

fn retire_outstanding_handle(self: anytype) void {
    if (self.outstanding_cmd_buf) |cb| {
        bridge.metal_bridge_release(cb);
        self.outstanding_cmd_buf = null;
    }
}

fn finalize_streaming_encoders(self: anytype) void {
    if (self.streaming_compute_encoder) |enc| {
        bridge.metal_bridge_end_compute_encoding(enc);
        self.streaming_compute_encoder = null;
    }
    if (self.streaming_render_encoder) |enc| {
        bridge.metal_bridge_render_encoder_end(enc);
        bridge.metal_bridge_release(enc);
        self.streaming_render_encoder = null;
    }
    if (self.streaming_blit_encoder) |enc| {
        bridge.metal_bridge_end_blit_encoding(enc);
        self.streaming_blit_encoder = null;
    }
}

fn recycle_streaming_uploads(self: anytype) void {
    for (self.streaming_uploads.items) |item| {
        if (item.src_buffer != null) {
            pool_push_or_release(&self.shared_pool, self.allocator, item.byte_count, item.src_buffer);
        }
        if (item.dst_buffer != null) {
            pool_push_or_release(&self.private_pool, self.allocator, item.byte_count, item.dst_buffer);
        }
    }
    self.streaming_uploads.clearRetainingCapacity();
}

pub fn transition_streaming_submission_deferred(self: anytype) !void {
    if (self.streaming_cmd_buf == null) return;
    if (self.streaming_gpu_timestamps_active) {
        _ = try flush_queue(self);
        return;
    }
    finalize_streaming_encoders(self);
    const cmd_buf = self.streaming_cmd_buf.?;

    self.fence_value +%= 1;
    if (self.shared_event) |ev| {
        bridge.metal_bridge_command_buffer_encode_signal_event(cmd_buf, ev, self.fence_value);
    }
    bridge.metal_bridge_command_buffer_commit(cmd_buf);

    // A later wait on the successor command buffer covers this committed work
    // too because both buffers execute in-order on the same Metal queue.
    retire_outstanding_handle(self);
    self.outstanding_cmd_buf = cmd_buf;
    self.has_deferred_submissions = true;
    self.streaming_cmd_buf = null;
    self.streaming_compute_dispatch_count = 0;
    self.streaming_has_render = false;
    self.streaming_has_copy = false;
    self.streaming_max_upload_bytes = 0;
    self.streaming_gpu_timestamps_active = false;
}

pub fn flush_queue_timed(self: anytype) !FlushResult {
    if (!self.has_device) return .{};
    const has_streaming = self.streaming_cmd_buf != null;
    if (!has_streaming and !self.has_deferred_submissions) return .{};
    const start_ns = common_timing.now_ns();
    var gpu_timestamps_attempted = false;
    var gpu_elapsed_ns: u64 = 0;
    if (has_streaming) {
        finalize_streaming_encoders(self);

        const cmd_buf = self.streaming_cmd_buf.?;

        gpu_timestamps_attempted = self.streaming_gpu_timestamps_active;
        if (self.streaming_gpu_timestamps_active) {
            self.timestamp_state.record_end(cmd_buf);
        }

        self.fence_value +%= 1;
        const use_scoped_wait =
            !gpu_timestamps_attempted and
            !self.streaming_has_render and
            (self.streaming_has_copy or self.streaming_max_upload_bytes >= metal_runtime_limits.FAST_WAIT_UPLOAD_THRESHOLD);
        const completion_waiter = if (use_scoped_wait)
            bridge.metal_bridge_command_buffer_create_completion_waiter(cmd_buf)
        else
            null;
        bridge.metal_bridge_command_buffer_commit(cmd_buf);
        if (gpu_timestamps_attempted) {
            bridge.metal_bridge_command_buffer_wait_completed(cmd_buf);
        } else if (completion_waiter != null) {
            bridge.metal_bridge_completion_waiter_wait_and_release(completion_waiter);
        } else {
            bridge.metal_bridge_command_buffer_wait_completed(cmd_buf);
        }

        // The current streaming submission's wait already implies completion of
        // any prior main-queue work, so keep deferred mode CPU-light by
        // dropping the older handle instead of waiting twice.
        retire_outstanding_handle(self);
        if (gpu_timestamps_attempted) {
            gpu_elapsed_ns = self.timestamp_state.resolve_elapsed_ns();
        }

        bridge.metal_bridge_release(cmd_buf);
        self.streaming_cmd_buf = null;
        self.streaming_compute_dispatch_count = 0;
        self.streaming_has_render = false;
        self.streaming_has_copy = false;
        self.streaming_max_upload_bytes = 0;
        self.streaming_gpu_timestamps_active = false;
    } else if (self.has_deferred_submissions) {
        if (self.outstanding_cmd_buf != null) {
            wait_outstanding(self);
        } else {
            const empty_cmd = bridge.metal_bridge_create_command_buffer(self.queue) orelse return error.InvalidState;
            bridge.metal_bridge_command_buffer_commit(empty_cmd);
            bridge.metal_bridge_command_buffer_wait_completed(empty_cmd);
            bridge.metal_bridge_release(empty_cmd);
        }
    }

    recycle_streaming_uploads(self);
    self.has_deferred_submissions = false;
    const end_ns = common_timing.now_ns();
    self.release_deferred_releases();
    self.deferred_pool.drain();
    return .{
        .submit_wait_ns = common_timing.ns_delta(end_ns, start_ns),
        .gpu_elapsed_ns = gpu_elapsed_ns,
        .gpu_timestamps_attempted = gpu_timestamps_attempted,
        .gpu_timestamps_valid = gpu_timestamps_attempted and gpu_elapsed_ns > 0,
    };
}

pub fn wait_outstanding(self: anytype) void {
    if (self.outstanding_cmd_buf) |cb| {
        if (self.shared_event) |ev| {
            bridge.metal_bridge_shared_event_wait(ev, self.fence_value);
        } else {
            bridge.metal_bridge_command_buffer_wait_completed(cb);
        }
        bridge.metal_bridge_release(cb);
        self.outstanding_cmd_buf = null;
    }
}

pub fn barrier(self: anytype, queue_wait_mode: webgpu.QueueWaitMode, queue_sync_mode: webgpu.QueueSyncMode) !u64 {
    _ = queue_wait_mode;
    if (queue_sync_mode == .deferred and self.streaming_cmd_buf == null and self.has_deferred_submissions) {
        const start_ns = common_timing.now_ns();
        if (self.outstanding_cmd_buf) |cb| {
            bridge.metal_bridge_release(cb);
            self.outstanding_cmd_buf = null;
        }
        const empty_cmd = bridge.metal_bridge_create_command_buffer(self.queue) orelse return error.InvalidState;
        self.fence_value +%= 1;
        if (self.shared_event) |ev| {
            bridge.metal_bridge_command_buffer_encode_signal_event(empty_cmd, ev, self.fence_value);
        }
        bridge.metal_bridge_command_buffer_commit(empty_cmd);
        self.outstanding_cmd_buf = empty_cmd;
        return common_timing.ns_delta(common_timing.now_ns(), start_ns);
    }

    const start_ns = common_timing.now_ns();
    if (self.streaming_cmd_buf != null or self.has_deferred_submissions) {
        _ = try flush_queue(self);
    }
    wait_outstanding(self);
    const end_ns = common_timing.now_ns();
    return common_timing.ns_delta(end_ns, start_ns);
}

pub fn prewarm_upload_path(self: anytype, max_upload_bytes: u64, mode: webgpu.UploadBufferUsageMode) !void {
    return metal_upload.prewarm_upload_path(self, max_upload_bytes, mode);
}

fn pool_push_or_release(
    pool: *metal_buffer_pool.BufferPool,
    allocator: std.mem.Allocator,
    size: usize,
    buf: ?*anyopaque,
) void {
    metal_buffer_pool.pool_push_or_release(pool, allocator, size, buf);
}
