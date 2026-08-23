const std = @import("std");
const common_timing = @import("../common/timing.zig");
const execution_contract = @import("../../contracts/execution.zig");
const webgpu = @import("../../contracts/runtime_types.zig");
const bridge = @import("metal_bridge_decls.zig");
const metal_bridge_buffer_contents = bridge.metal_bridge_buffer_contents;
const metal_bridge_command_buffer_commit = bridge.metal_bridge_command_buffer_commit;
const metal_bridge_command_buffer_encode_signal_event = bridge.metal_bridge_command_buffer_encode_signal_event;
const metal_bridge_create_command_buffer = bridge.metal_bridge_create_command_buffer;
const metal_bridge_cmd_buf_encode_compute_dispatch = bridge.metal_bridge_cmd_buf_encode_compute_dispatch;
const metal_bridge_cmd_buf_encode_compute_dispatch_indirect = bridge.metal_bridge_cmd_buf_encode_compute_dispatch_indirect;
const metal_bridge_command_buffer_wait_completed = bridge.metal_bridge_command_buffer_wait_completed;
const metal_bridge_device_new_buffer_shared = bridge.metal_bridge_device_new_buffer_shared;
const metal_bridge_release = bridge.metal_bridge_release;

const DEFAULT_DISPATCH_KERNEL = "dispatch_noop.metal";
const DISPATCH_INDIRECT_ARGS_BYTES = @sizeOf([3]u32);
const DEFAULT_WORKGROUP_SIZE: u32 = 0;

pub const DispatchRunMetrics = execution_contract.DispatchMetrics;

pub fn run_dispatch(runtime: anytype, x: u32, y: u32, z: u32, queue_sync_mode: webgpu.QueueSyncMode) !DispatchRunMetrics {
    if (x == 0 or y == 0 or z == 0) return error.InvalidArgument;
    try prepare_dispatch_submission(runtime, queue_sync_mode);
    const pipeline = try runtime.ensure_kernel_pipeline(DEFAULT_DISPATCH_KERNEL, null);
    const encode_start = common_timing.now_ns();
    const cmd_buf = metal_bridge_create_command_buffer(runtime.queue) orelse return error.InvalidState;
    metal_bridge_cmd_buf_encode_compute_dispatch(
        cmd_buf,
        pipeline,
        null,
        0,
        x,
        y,
        z,
        DEFAULT_WORKGROUP_SIZE,
        DEFAULT_WORKGROUP_SIZE,
        DEFAULT_WORKGROUP_SIZE,
    );
    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);
    const submit_wait_ns = finalize_dispatch_submission(runtime, cmd_buf, queue_sync_mode);
    return .{ .encode_ns = encode_ns, .submit_wait_ns = submit_wait_ns, .dispatch_count = 1 };
}

pub fn run_dispatch_indirect(runtime: anytype, x: u32, y: u32, z: u32, queue_sync_mode: webgpu.QueueSyncMode) !DispatchRunMetrics {
    if (x == 0 or y == 0 or z == 0) return error.InvalidArgument;
    try prepare_dispatch_submission(runtime, queue_sync_mode);
    const pipeline = try runtime.ensure_kernel_pipeline(DEFAULT_DISPATCH_KERNEL, null);
    const indirect_buffer = try ensure_dispatch_indirect_args_buffer(runtime);
    try write_dispatch_indirect_args(indirect_buffer, x, y, z);
    const encode_start = common_timing.now_ns();
    const cmd_buf = metal_bridge_create_command_buffer(runtime.queue) orelse return error.InvalidState;
    metal_bridge_cmd_buf_encode_compute_dispatch_indirect(
        cmd_buf,
        pipeline,
        null,
        0,
        indirect_buffer,
        0,
        DEFAULT_WORKGROUP_SIZE,
        DEFAULT_WORKGROUP_SIZE,
        DEFAULT_WORKGROUP_SIZE,
    );
    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);
    const submit_wait_ns = finalize_dispatch_submission(runtime, cmd_buf, queue_sync_mode);
    return .{ .encode_ns = encode_ns, .submit_wait_ns = submit_wait_ns, .dispatch_count = 1 };
}

fn ensure_dispatch_indirect_args_buffer(runtime: anytype) !?*anyopaque {
    if (runtime.dispatch_indirect_args_buffer == null) {
        runtime.dispatch_indirect_args_buffer = metal_bridge_device_new_buffer_shared(runtime.device, DISPATCH_INDIRECT_ARGS_BYTES) orelse return error.InvalidState;
    }
    return runtime.dispatch_indirect_args_buffer.?;
}

fn write_dispatch_indirect_args(buffer: ?*anyopaque, x: u32, y: u32, z: u32) !void {
    const mapped = metal_bridge_buffer_contents(buffer) orelse return error.InvalidState;
    const dispatch_args = [3]u32{ x, y, z };
    const dispatch_arg_bytes = std.mem.asBytes(&dispatch_args);
    @memcpy(mapped[0..dispatch_arg_bytes.len], dispatch_arg_bytes);
}

fn prepare_dispatch_submission(runtime: anytype, queue_sync_mode: webgpu.QueueSyncMode) !void {
    if (queue_sync_mode == .deferred) {
        if (runtime.streaming_cmd_buf != null) {
            try runtime.transition_streaming_submission_deferred();
        }
        if (runtime.outstanding_cmd_buf) |previous| {
            metal_bridge_release(previous);
            runtime.outstanding_cmd_buf = null;
        }
        return;
    }
    if (runtime.streaming_cmd_buf != null or runtime.has_deferred_submissions or runtime.outstanding_cmd_buf != null) {
        _ = try runtime.flush_queue();
    }
}

fn finalize_dispatch_submission(runtime: anytype, cmd_buf: ?*anyopaque, queue_sync_mode: webgpu.QueueSyncMode) u64 {
    if (queue_sync_mode == .deferred) {
        runtime.fence_value +%= 1;
        if (runtime.shared_event) |ev| {
            metal_bridge_command_buffer_encode_signal_event(cmd_buf, ev, runtime.fence_value);
        }
        metal_bridge_command_buffer_commit(cmd_buf);
        runtime.has_deferred_submissions = true;
        runtime.outstanding_cmd_buf = cmd_buf;
        return 0;
    }
    metal_bridge_command_buffer_commit(cmd_buf);
    const submit_start = common_timing.now_ns();
    metal_bridge_command_buffer_wait_completed(cmd_buf);
    const submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_start);
    metal_bridge_release(cmd_buf);
    return submit_wait_ns;
}
