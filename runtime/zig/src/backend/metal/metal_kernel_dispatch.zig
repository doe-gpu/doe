const common_timing = @import("../common/timing.zig");
const execution_contract = @import("../../contracts/execution.zig");
const model_transfer_types = @import("../../contracts/model/model_compute_types.zig");
const webgpu = @import("../../contracts/runtime_types.zig");
const bridge = @import("metal_bridge_decls.zig");

const metal_bridge_cmd_buf_compute_encoder = bridge.metal_bridge_cmd_buf_compute_encoder;
const metal_bridge_command_buffer_commit = bridge.metal_bridge_command_buffer_commit;
const metal_bridge_command_buffer_wait_completed = bridge.metal_bridge_command_buffer_wait_completed;
const metal_bridge_create_command_buffer = bridge.metal_bridge_create_command_buffer;
const metal_bridge_compute_encoder_encode_dispatch = bridge.metal_bridge_compute_encoder_encode_dispatch;
const metal_bridge_encode_compute_dispatch_batch = bridge.metal_bridge_encode_compute_dispatch_batch;
const metal_bridge_end_blit_encoding = bridge.metal_bridge_end_blit_encoding;
const metal_bridge_release = bridge.metal_bridge_release;
const metal_bridge_render_encoder_end = bridge.metal_bridge_render_encoder_end;

const model = struct {
    pub const KernelBinding = model_transfer_types.KernelBinding;
};

pub const MAX_BINDING_SLOTS: usize = 32;
const MAX_STREAMING_COMPUTE_DISPATCHES_BEFORE_COMMIT: u32 = 256;

pub const DispatchMetrics = execution_contract.DispatchMetrics;

pub const KernelDispatchResult = struct {
    metrics: DispatchMetrics,
    gpu_elapsed_ns: u64 = 0,
    gpu_timestamps_attempted: bool = false,
    gpu_timestamps_valid: bool = false,
};

pub fn run_kernel_dispatch(
    runtime: anytype,
    kernel: []const u8,
    entry_point: ?[]const u8,
    x: u32,
    y: u32,
    z: u32,
    repeat: u32,
    warmup: u32,
    initialize_buffers_on_create: bool,
    bindings: ?[]const model.KernelBinding,
) !DispatchMetrics {
    const result = try run_kernel_dispatch_timed(runtime, kernel, entry_point, x, y, z, repeat, warmup, initialize_buffers_on_create, bindings, .per_command, false);
    return result.metrics;
}

pub fn run_kernel_dispatch_timed(
    runtime: anytype,
    kernel: []const u8,
    entry_point: ?[]const u8,
    x: u32,
    y: u32,
    z: u32,
    repeat: u32,
    warmup: u32,
    initialize_buffers_on_create: bool,
    bindings: ?[]const model.KernelBinding,
    queue_sync_mode: webgpu.QueueSyncMode,
    record_timestamps: bool,
) !KernelDispatchResult {
    // Setup: pipeline compile, buffer allocation, warmup dispatches.
    const setup_start = common_timing.now_ns();
    const pipeline_info = try runtime.ensure_kernel_pipeline_info(kernel, entry_point);
    const pipeline = pipeline_info.pipeline;
    const workgroup_size = pipeline_info.workgroup_size;

    var buf_slots: [MAX_BINDING_SLOTS]?*anyopaque = [_]?*anyopaque{null} ** MAX_BINDING_SLOTS;
    var slot_count: u32 = 0;

    if (bindings) |bs| {
        for (bs) |b| {
            if (b.resource_kind != .buffer) continue;
            if (b.binding >= MAX_BINDING_SLOTS) continue;
            buf_slots[b.binding] = try runtime.ensure_compute_buffer(b.resource_handle, b.buffer_size, initialize_buffers_on_create);
            if (b.binding + 1 > slot_count) slot_count = @intCast(b.binding + 1);
        }
    }

    const run_count: u32 = if (repeat == 0) 1 else repeat;
    const buf_ptr: ?[*]?*anyopaque = if (slot_count > 0) &buf_slots else null;

    if (warmup > 0) {
        const wcb = metal_bridge_encode_compute_dispatch_batch(
            runtime.queue,
            pipeline,
            buf_ptr,
            slot_count,
            x,
            y,
            z,
            warmup,
            workgroup_size[0],
            workgroup_size[1],
            workgroup_size[2],
        ) orelse return error.InvalidState;
        commitAndWait(wcb);
        metal_bridge_release(wcb);
    }
    const setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);

    const want_ts = record_timestamps and runtime.timestamp_state.supported;

    if (!want_ts and queue_sync_mode == .deferred) {
        const encode_start = common_timing.now_ns();
        try ensure_streaming_compute_encoder(runtime);
        var i: u32 = 0;
        while (i < run_count) : (i += 1) {
            metal_bridge_compute_encoder_encode_dispatch(
                runtime.streaming_compute_encoder,
                pipeline,
                buf_ptr,
                slot_count,
                x,
                y,
                z,
                workgroup_size[0],
                workgroup_size[1],
                workgroup_size[2],
            );
        }
        var encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);
        runtime.streaming_compute_dispatch_count +|= run_count;
        runtime.has_deferred_submissions = true;
        if (runtime.streaming_compute_dispatch_count >= MAX_STREAMING_COMPUTE_DISPATCHES_BEFORE_COMMIT) {
            const rollover_start = common_timing.now_ns();
            try runtime.transition_streaming_submission_deferred();
            encode_ns +|= common_timing.ns_delta(common_timing.now_ns(), rollover_start);
        }
        return .{
            .metrics = .{
                .setup_ns = setup_ns,
                .encode_ns = encode_ns,
                .submit_wait_ns = 0,
                .dispatch_count = run_count,
            },
            .gpu_elapsed_ns = 0,
            .gpu_timestamps_attempted = false,
            .gpu_timestamps_valid = false,
        };
    }

    // Timed run: batch all repeat dispatches into one command buffer.
    const t_enc_start = common_timing.now_ns();

    const cmd_buf = if (want_ts) blk: {
        // When recording GPU timestamps, create the command buffer
        // manually so we can bracket the compute work with timestamp
        // samples in the correct GPU timeline order.
        const cb = metal_bridge_create_command_buffer(runtime.queue) orelse return error.InvalidState;
        runtime.timestamp_state.record_begin(cb);
        var i: u32 = 0;
        while (i < run_count) : (i += 1) {
            bridge.metal_bridge_cmd_buf_encode_compute_dispatch(
                cb,
                pipeline,
                buf_ptr,
                slot_count,
                x,
                y,
                z,
                workgroup_size[0],
                workgroup_size[1],
                workgroup_size[2],
            );
        }
        runtime.timestamp_state.record_end(cb);
        break :blk cb;
    } else blk: {
        break :blk metal_bridge_encode_compute_dispatch_batch(
            runtime.queue,
            pipeline,
            buf_ptr,
            slot_count,
            x,
            y,
            z,
            run_count,
            workgroup_size[0],
            workgroup_size[1],
            workgroup_size[2],
        ) orelse return error.InvalidState;
    };

    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), t_enc_start);

    const t_sub_start = common_timing.now_ns();
    commitAndWait(cmd_buf);
    const submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), t_sub_start);

    var gpu_elapsed_ns: u64 = 0;
    if (want_ts) {
        gpu_elapsed_ns = runtime.timestamp_state.resolve_elapsed_ns();
    }

    metal_bridge_release(cmd_buf);

    return .{
        .metrics = .{
            .setup_ns = setup_ns,
            .encode_ns = encode_ns,
            .submit_wait_ns = submit_wait_ns,
            .dispatch_count = run_count,
        },
        .gpu_elapsed_ns = gpu_elapsed_ns,
        .gpu_timestamps_attempted = want_ts,
        .gpu_timestamps_valid = want_ts and gpu_elapsed_ns > 0,
    };
}

fn commitAndWait(cmd_buf: ?*anyopaque) void {
    metal_bridge_command_buffer_commit(cmd_buf);
    metal_bridge_command_buffer_wait_completed(cmd_buf);
}

fn ensure_streaming_compute_encoder(runtime: anytype) !void {
    if (runtime.streaming_compute_encoder != null) return;

    if (runtime.streaming_render_encoder) |enc| {
        metal_bridge_render_encoder_end(enc);
        metal_bridge_release(enc);
        runtime.streaming_render_encoder = null;
    }
    if (runtime.streaming_blit_encoder) |enc| {
        metal_bridge_end_blit_encoding(enc);
        runtime.streaming_blit_encoder = null;
    }
    if (runtime.streaming_cmd_buf == null) {
        runtime.streaming_cmd_buf = metal_bridge_create_command_buffer(runtime.queue) orelse return error.InvalidState;
    }
    runtime.streaming_compute_encoder = metal_bridge_cmd_buf_compute_encoder(runtime.streaming_cmd_buf) orelse return error.InvalidState;
}
