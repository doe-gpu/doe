const std = @import("std");
const model_resource_types = @import("../../../contracts/model/model_resource_types.zig");
const model_gpu_types = @import("../../../contracts/model/model_texture_value_types.zig");
const common_timing = @import("../../common/timing.zig");
const d3d12_texture = @import("../resources/d3d12_texture.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

const HEAP_TYPE_DEFAULT: c_int = 1;

pub const CopyMetrics = struct {
    setup_ns: u64 = 0,
    encode_ns: u64 = 0,
    submit_wait_ns: u64 = 0,
};

/// Streaming copy state for D3D12. Keeps a single command list open across multiple
/// copy operations. The list is closed, executed, and waited on only when flush() is
/// called -- typically before a compute/render command or at queue flush/barrier.
/// This eliminates per-copy command allocator/list creation and per-copy fence waits,
/// matching the Metal streaming blit encoder pattern.
pub const StreamingCopyState = struct {
    cmd_allocator: ?*anyopaque = null,
    cmd_list: ?*anyopaque = null,
    has_cmd: bool = false,
    is_recording: bool = false,
    pending_count: u32 = 0,

    /// Ensure the persistent command allocator and list exist. Created once,
    /// then reset+reused on each new recording batch.
    fn ensure_cmd(self: *StreamingCopyState, device: ?*anyopaque) !void {
        if (self.has_cmd) return;
        self.cmd_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(device) orelse return error.InvalidState;
        self.cmd_list = bridge.c.d3d12_bridge_device_create_command_list(device, self.cmd_allocator) orelse {
            bridge.c.d3d12_bridge_release(self.cmd_allocator);
            self.cmd_allocator = null;
            return error.InvalidState;
        };
        // Close immediately -- reset+reopen when recording starts.
        bridge.c.d3d12_bridge_command_list_close(self.cmd_list);
        self.has_cmd = true;
    }

    /// Open (or keep open) the command list for recording copy commands.
    fn ensure_recording(self: *StreamingCopyState, device: ?*anyopaque) !void {
        try self.ensure_cmd(device);
        if (self.is_recording) return;
        if (bridge.c.d3d12_bridge_command_allocator_reset(self.cmd_allocator) != 0) return error.InvalidState;
        if (bridge.c.d3d12_bridge_command_list_reset(self.cmd_list, self.cmd_allocator) != 0) return error.InvalidState;
        self.is_recording = true;
        self.pending_count = 0;
    }

    /// Record a single copy command into the open command list without executing.
    pub fn record_copy(
        self: *StreamingCopyState,
        device: ?*anyopaque,
        texture_map: *d3d12_texture.TextureMap,
        allocator: std.mem.Allocator,
        cmd: model_resource_types.CopyCommand,
    ) !CopyMetrics {
        if (cmd.bytes == 0) return error.InvalidArgument;

        const setup_start = common_timing.now_ns();

        const src_resource = resolve_resource(device, texture_map, allocator, cmd.src) orelse return error.InvalidState;
        const dst_resource = resolve_resource(device, texture_map, allocator, cmd.dst) orelse return error.InvalidState;

        const setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);

        const encode_start = common_timing.now_ns();

        try self.ensure_recording(device);

        switch (cmd.direction) {
            .buffer_to_buffer => {
                bridge.c.d3d12_bridge_command_list_copy_buffer(self.cmd_list, dst_resource, src_resource, cmd.bytes);
            },
            .buffer_to_texture => {
                const width = if (cmd.dst.width > 0) cmd.dst.width else 1;
                const height = if (cmd.dst.height > 0) cmd.dst.height else 1;
                const bpr = if (cmd.dst.bytes_per_row > 0) cmd.dst.bytes_per_row else @as(u32, @intCast(cmd.bytes / height));
                const format: u32 = if (cmd.dst.format != model_gpu_types.WGPUTextureFormat_Undefined) cmd.dst.format else model_gpu_types.WGPUTextureFormat_RGBA8Unorm;
                bridge.c.d3d12_bridge_command_list_copy_texture_region(self.cmd_list, dst_resource, src_resource, cmd.src.offset, width, height, bpr, format);
            },
            .texture_to_buffer, .texture_to_texture => {
                bridge.c.d3d12_bridge_command_list_copy_buffer(self.cmd_list, dst_resource, src_resource, cmd.bytes);
            },
        }

        self.pending_count += 1;
        const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

        return .{ .setup_ns = setup_ns, .encode_ns = encode_ns, .submit_wait_ns = 0 };
    }

    /// Close the command list, execute on the queue, signal the fence, and wait.
    /// Returns the submit+wait time in nanoseconds. No-op if nothing is recording.
    pub fn flush(
        self: *StreamingCopyState,
        queue: ?*anyopaque,
        fence: ?*anyopaque,
        fence_value: *u64,
    ) !u64 {
        if (!self.is_recording) return 0;

        bridge.c.d3d12_bridge_command_list_close(self.cmd_list);
        self.is_recording = false;

        const submit_start = common_timing.now_ns();
        bridge.c.d3d12_bridge_queue_execute_command_list(queue, self.cmd_list);
        fence_value.* +|= 1;
        bridge.c.d3d12_bridge_queue_signal(queue, fence, fence_value.*);
        bridge.c.d3d12_bridge_fence_wait(fence, fence_value.*);
        const submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_start);

        self.pending_count = 0;
        return submit_wait_ns;
    }

    /// Returns true when there are copy commands recorded but not yet flushed.
    pub fn has_pending(self: *const StreamingCopyState) bool {
        return self.is_recording and self.pending_count > 0;
    }

    pub fn deinit(self: *StreamingCopyState) void {
        if (self.has_cmd) {
            bridge.c.d3d12_bridge_release(self.cmd_list);
            bridge.c.d3d12_bridge_release(self.cmd_allocator);
            self.cmd_list = null;
            self.cmd_allocator = null;
            self.has_cmd = false;
            self.is_recording = false;
            self.pending_count = 0;
        }
    }
};

fn resolve_resource(
    device: ?*anyopaque,
    texture_map: *d3d12_texture.TextureMap,
    allocator: std.mem.Allocator,
    res: model_resource_types.CopyTextureResource,
) ?*anyopaque {
    if (res.kind == .texture) {
        if (texture_map.get(res.handle)) |entry| return entry.resource;
        const width = if (res.width > 0) res.width else 1;
        const height = if (res.height > 0) res.height else 1;
        const format: u32 = if (res.format != model_gpu_types.WGPUTextureFormat_Undefined) res.format else model_gpu_types.WGPUTextureFormat_RGBA8Unorm;
        _ = @as(u32, @truncate(res.usage));
        const tex = bridge.c.d3d12_bridge_device_create_buffer(device, @as(usize, width) * @as(usize, height) * 4, HEAP_TYPE_DEFAULT) orelse return null;
        texture_map.put(allocator, res.handle, .{
            .handle = res.handle,
            .resource = tex,
            .width = width,
            .height = height,
            .format = format,
            .usage = res.usage,
        }) catch {
            bridge.c.d3d12_bridge_release(tex);
            return null;
        };
        return tex;
    }
    return bridge.c.d3d12_bridge_device_create_buffer(device, if (res.offset > 0) @intCast(res.offset) else 256, HEAP_TYPE_DEFAULT);
}
