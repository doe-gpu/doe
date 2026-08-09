const std = @import("std");
const model_compute_types = @import("../../../contracts/model/model_compute_types.zig");
const execution_contract = @import("../../../contracts/execution.zig");
const common_timing = @import("../../common/timing.zig");
const webgpu = @import("../../runtime_types.zig");
const dc = @import("../d3d12_constants.zig");
const bridge = @import("../d3d12_bridge_decls.zig");

const DISPATCH_INDIRECT_ARG_BYTES: usize = 12;

pub const DispatchMetrics = execution_contract.DispatchMetrics;

pub const DispatchSubmission = struct {
    metrics: DispatchMetrics = .{},
    cmd_allocator: ?*anyopaque = null,
    cmd_list: ?*anyopaque = null,
};

pub const DispatchState = struct {
    root_signature: ?*anyopaque = null,
    noop_pipeline: ?*anyopaque = null,
    cmd_allocator: ?*anyopaque = null,
    cmd_list: ?*anyopaque = null,
    has_cmd: bool = false,
    dispatch_cmd_sig: ?*anyopaque = null,
    indirect_arg_buffer: ?*anyopaque = null,

    pub fn execute_dispatch(
        self: *DispatchState,
        device: ?*anyopaque,
        queue: ?*anyopaque,
        fence: ?*anyopaque,
        fence_value: *u64,
        cmd: model_compute_types.DispatchCommand,
        queue_sync_mode: webgpu.QueueSyncMode,
    ) !DispatchSubmission {
        if (cmd.x == 0 or cmd.y == 0 or cmd.z == 0) return error.InvalidArgument;

        try self.ensure_noop_pipeline(device);
        if (queue_sync_mode == .per_command) {
            try self.ensure_cmd(device);
        }

        var cmd_allocator = self.cmd_allocator;
        var cmd_list = self.cmd_list;
        if (queue_sync_mode != .per_command) {
            cmd_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(device) orelse return error.InvalidState;
            errdefer bridge.c.d3d12_bridge_release(cmd_allocator);
            cmd_list = bridge.c.d3d12_bridge_device_create_command_list(device, cmd_allocator) orelse return error.InvalidState;
            errdefer bridge.c.d3d12_bridge_release(cmd_list);
            bridge.c.d3d12_bridge_command_list_close(cmd_list);
        }

        const encode_start = common_timing.now_ns();

        if (bridge.c.d3d12_bridge_command_allocator_reset(cmd_allocator) != 0) return error.InvalidState;
        if (bridge.c.d3d12_bridge_command_list_reset(cmd_list, cmd_allocator) != 0) return error.InvalidState;

        bridge.c.d3d12_bridge_command_list_set_compute_root_signature(cmd_list, self.root_signature);
        bridge.c.d3d12_bridge_command_list_set_pipeline_state(cmd_list, self.noop_pipeline);
        bridge.c.d3d12_bridge_command_list_dispatch(cmd_list, cmd.x, cmd.y, cmd.z);
        bridge.c.d3d12_bridge_command_list_close(cmd_list);

        const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

        bridge.c.d3d12_bridge_queue_execute_command_list(queue, cmd_list);
        fence_value.* +|= 1;
        bridge.c.d3d12_bridge_queue_signal(queue, fence, fence_value.*);
        if (queue_sync_mode == .per_command) {
            const submit_start = common_timing.now_ns();
            bridge.c.d3d12_bridge_fence_wait(fence, fence_value.*);
            const submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_start);
            return .{ .metrics = .{ .encode_ns = encode_ns, .submit_wait_ns = submit_wait_ns, .dispatch_count = 1 } };
        }

        return .{
            .metrics = .{ .encode_ns = encode_ns, .submit_wait_ns = 0, .dispatch_count = 1 },
            .cmd_allocator = cmd_allocator,
            .cmd_list = cmd_list,
        };
    }

    pub fn execute_dispatch_indirect(
        self: *DispatchState,
        device: ?*anyopaque,
        queue: ?*anyopaque,
        fence: ?*anyopaque,
        fence_value: *u64,
        cmd: model_compute_types.DispatchIndirectCommand,
        queue_sync_mode: webgpu.QueueSyncMode,
    ) !DispatchSubmission {
        _ = cmd;
        try self.ensure_noop_pipeline(device);
        if (queue_sync_mode == .per_command) {
            try self.ensure_cmd(device);
        }

        if (self.dispatch_cmd_sig == null) {
            self.dispatch_cmd_sig = bridge.c.d3d12_bridge_device_create_command_signature_dispatch(device, self.root_signature) orelse return error.InvalidState;
        }
        if (self.indirect_arg_buffer == null) {
            self.indirect_arg_buffer = bridge.c.d3d12_bridge_device_create_buffer(device, DISPATCH_INDIRECT_ARG_BYTES, dc.HEAP_TYPE_UPLOAD) orelse return error.InvalidState;
        }

        var cmd_allocator = self.cmd_allocator;
        var cmd_list = self.cmd_list;
        if (queue_sync_mode != .per_command) {
            cmd_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(device) orelse return error.InvalidState;
            errdefer bridge.c.d3d12_bridge_release(cmd_allocator);
            cmd_list = bridge.c.d3d12_bridge_device_create_command_list(device, cmd_allocator) orelse return error.InvalidState;
            errdefer bridge.c.d3d12_bridge_release(cmd_list);
            bridge.c.d3d12_bridge_command_list_close(cmd_list);
        }

        const encode_start = common_timing.now_ns();

        if (bridge.c.d3d12_bridge_command_allocator_reset(cmd_allocator) != 0) return error.InvalidState;
        if (bridge.c.d3d12_bridge_command_list_reset(cmd_list, cmd_allocator) != 0) return error.InvalidState;

        bridge.c.d3d12_bridge_command_list_set_compute_root_signature(cmd_list, self.root_signature);
        bridge.c.d3d12_bridge_command_list_set_pipeline_state(cmd_list, self.noop_pipeline);
        bridge.c.d3d12_bridge_command_list_execute_indirect(cmd_list, self.dispatch_cmd_sig, 1, self.indirect_arg_buffer, 0);
        bridge.c.d3d12_bridge_command_list_close(cmd_list);

        const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

        bridge.c.d3d12_bridge_queue_execute_command_list(queue, cmd_list);
        fence_value.* +|= 1;
        bridge.c.d3d12_bridge_queue_signal(queue, fence, fence_value.*);
        if (queue_sync_mode == .per_command) {
            const submit_start = common_timing.now_ns();
            bridge.c.d3d12_bridge_fence_wait(fence, fence_value.*);
            const submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_start);
            return .{ .metrics = .{ .encode_ns = encode_ns, .submit_wait_ns = submit_wait_ns, .dispatch_count = 1 } };
        }

        return .{
            .metrics = .{ .encode_ns = encode_ns, .submit_wait_ns = 0, .dispatch_count = 1 },
            .cmd_allocator = cmd_allocator,
            .cmd_list = cmd_list,
        };
    }

    fn ensure_noop_pipeline(self: *DispatchState, device: ?*anyopaque) !void {
        if (self.noop_pipeline != null) return;
        if (self.root_signature == null) {
            self.root_signature = bridge.c.d3d12_bridge_device_create_root_signature_empty(device) orelse return error.InvalidState;
        }
        const noop_dxil = noop_compute_bytecode();
        self.noop_pipeline = bridge.c.d3d12_bridge_device_create_compute_pipeline(
            device,
            self.root_signature,
            noop_dxil.ptr,
            noop_dxil.len,
        ) orelse return error.ShaderCompileFailed;
    }

    fn ensure_cmd(self: *DispatchState, device: ?*anyopaque) !void {
        if (self.has_cmd) return;
        self.cmd_allocator = bridge.c.d3d12_bridge_device_create_command_allocator(device) orelse return error.InvalidState;
        self.cmd_list = bridge.c.d3d12_bridge_device_create_command_list(device, self.cmd_allocator) orelse return error.InvalidState;
        bridge.c.d3d12_bridge_command_list_close(self.cmd_list);
        self.has_cmd = true;
    }

    pub fn deinit(self: *DispatchState) void {
        if (self.has_cmd) {
            bridge.c.d3d12_bridge_release(self.cmd_list);
            bridge.c.d3d12_bridge_release(self.cmd_allocator);
            self.has_cmd = false;
        }
        if (self.noop_pipeline) |p| bridge.c.d3d12_bridge_release(p);
        if (self.root_signature) |r| bridge.c.d3d12_bridge_release(r);
        if (self.dispatch_cmd_sig) |s| bridge.c.d3d12_bridge_release(s);
        if (self.indirect_arg_buffer) |b| bridge.c.d3d12_bridge_release(b);
        self.* = .{};
    }
};

fn noop_compute_bytecode() []const u8 {
    // Minimal DXBC compute shader: [numthreads(1,1,1)] void main() {}
    // This is the pre-compiled DXBC bytecode for the simplest possible compute shader.
    const bytecode = [_]u8{
        0x44, 0x58, 0x42, 0x43, // DXBC magic
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // checksum placeholder
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, // version
        0x44, 0x00, 0x00, 0x00, // total size
        0x01, 0x00, 0x00, 0x00, // chunk count
        0x24, 0x00, 0x00, 0x00, // chunk offset
        0x53, 0x48, 0x45, 0x58, // SHEX
        0x18, 0x00, 0x00, 0x00, // chunk size
        0x50, 0x00, 0x05, 0x00, // version (5.0 compute)
        0x02, 0x00, 0x00, 0x00, // instruction count
        0x00, 0x00, 0x08, 0x9A, // dcl_thread_group 1,1,1
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x3E, 0x00, 0x00, 0x01, // ret
    };
    return &bytecode;
}
