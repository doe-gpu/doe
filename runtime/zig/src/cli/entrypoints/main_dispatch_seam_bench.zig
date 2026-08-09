//! Source-bound diagnostic benchmark for the promoted dispatch seam.

const std = @import("std");
const doe = @import("doe");
const backend_iface = doe.backend.iface();
const backend_telemetry = doe.backend.telemetry();
const compute = doe.contracts.compute();
const command = doe.contracts.command();
const model_compute = doe.contracts.model.computeTypes();
const runtime_types = doe.backend.runtimeTypes();

const SAMPLE_COUNT: usize = 21;
const CALLS_PER_SAMPLE: usize = 200_000;

const State = struct {
    calls: u64 = 0,
    checksum: u64 = 0,

    fn cast(context: *anyopaque) *State {
        return @ptrCast(@alignCast(context));
    }

    fn deinit(_: *anyopaque) void {}

    fn executeCommand(context: *anyopaque, value: command.Command) anyerror!runtime_types.NativeExecutionResult {
        const dispatch = switch (value) {
            .kernel_dispatch => |payload| payload,
            else => return error.InvalidArgument,
        };
        return record(cast(context), dispatch.x, dispatch.y, dispatch.z, dispatch.repeat);
    }

    fn executeDispatch(context: compute.ComputeContext, request: compute.DispatchRequest) anyerror!compute.DispatchReport {
        return .{ .execution = record(
            cast(context.state),
            request.workgroups.x,
            request.workgroups.y,
            request.workgroups.z,
            request.repeat,
        ) };
    }

    fn record(self: *State, x: u32, y: u32, z: u32, repeat: u32) runtime_types.NativeExecutionResult {
        const calls: *volatile u64 = &self.calls;
        const checksum: *volatile u64 = &self.checksum;
        calls.* +%= 1;
        checksum.* +%= @as(u64, x) *% 3 +% @as(u64, y) *% 5 +% @as(u64, z) *% 7 +% repeat;
        return .{ .status = .ok, .status_message = "", .dispatch_count = repeat };
    }

    fn executeBufferWriteBytes(_: *anyopaque, _: u64, _: u64, _: u64, _: []const u8) anyerror!runtime_types.NativeExecutionResult {
        return error.Unsupported;
    }
    fn setUploadBehavior(_: *anyopaque, _: runtime_types.UploadBufferUsageMode, _: u32) void {}
    fn setQueueWaitMode(_: *anyopaque, _: runtime_types.QueueWaitMode) void {}
    fn setTimeout(_: *anyopaque, _: u64) void {}
    fn setQueueSyncMode(_: *anyopaque, _: runtime_types.QueueSyncMode) void {}
    fn setGpuTimestampMode(_: *anyopaque, _: runtime_types.GpuTimestampMode) void {}
    fn flushQueue(_: *anyopaque) anyerror!u64 {
        return 0;
    }
    fn prewarmUploadPath(_: *anyopaque, _: u64) anyerror!void {}
    fn prewarmKernelDispatch(_: *anyopaque, _: []const u8, _: ?[]const u8, _: ?[]const model_compute.KernelBinding, _: bool) anyerror!void {}
    fn captureBuffer(_: *anyopaque, allocator: std.mem.Allocator, _: u64, _: u64, _: u64) anyerror![]u8 {
        return allocator.alloc(u8, 0);
    }
};

const vtable = backend_iface.BackendVTable{
    .deinit = State.deinit,
    .execute_command = State.executeCommand,
    .execute_dispatch = State.executeDispatch,
    .execute_buffer_write_bytes = State.executeBufferWriteBytes,
    .set_upload_behavior = State.setUploadBehavior,
    .set_queue_wait_mode = State.setQueueWaitMode,
    .set_webgpu_ffi_queue_wait_timeout_ns = State.setTimeout,
    .set_queue_sync_mode = State.setQueueSyncMode,
    .set_gpu_timestamp_mode = State.setGpuTimestampMode,
    .flush_queue = State.flushQueue,
    .prewarm_upload_path = State.prewarmUploadPath,
    .prewarm_kernel_dispatch = State.prewarmKernelDispatch,
    .capture_buffer = State.captureBuffer,
};

pub fn main() !void {
    var state = State{};
    var iface = backend_iface.BackendIface{
        .id = .doe_vulkan,
        .context = &state,
        .vtable = &vtable,
        .telemetry = telemetry(),
    };
    const value = command.Command{ .kernel_dispatch = .{
        .kernel = "dispatch-seam-benchmark.wgsl",
        .x = 3,
        .y = 5,
        .z = 7,
        .repeat = 11,
    } };
    const request = compute.DispatchRequest.fromCommand(value.kernel_dispatch);

    var legacy_samples: [SAMPLE_COUNT]u64 = undefined;
    var promoted_samples: [SAMPLE_COUNT]u64 = undefined;
    _ = try vtable.execute_command(iface.context, value);
    _ = try iface.execute_command(value);
    for (0..SAMPLE_COUNT) |sample| {
        legacy_samples[sample] = try measureLegacy(&iface, value);
        promoted_samples[sample] = try measurePromoted(&iface, request);
    }
    std.mem.sort(u64, &legacy_samples, {}, std.sort.asc(u64));
    std.mem.sort(u64, &promoted_samples, {}, std.sort.asc(u64));
    const middle = SAMPLE_COUNT / 2;
    std.mem.doNotOptimizeAway(state.checksum);
    try std.fs.File.stdout().deprecatedWriter().print(
        "{{\"callsPerSample\":{d},\"characterizedLegacyMedianNs\":{d},\"measurementClass\":\"diagnostic-only\",\"promotedMedianNs\":{d},\"sampleCount\":{d},\"schemaVersion\":1,\"stateCalls\":{d},\"status\":\"captured\"}}\n",
        .{ CALLS_PER_SAMPLE, legacy_samples[middle], promoted_samples[middle], SAMPLE_COUNT, state.calls },
    );
}

fn measureLegacy(iface: *backend_iface.BackendIface, value: command.Command) !u64 {
    var timer = try std.time.Timer.start();
    for (0..CALLS_PER_SAMPLE) |_| {
        const result = try iface.vtable.execute_command(iface.context, value);
        std.mem.doNotOptimizeAway(result.dispatch_count);
    }
    return timer.read();
}

fn measurePromoted(iface: *backend_iface.BackendIface, request: compute.DispatchRequest) !u64 {
    var timer = try std.time.Timer.start();
    for (0..CALLS_PER_SAMPLE) |_| {
        const result = try iface.execute_dispatch(request);
        std.mem.doNotOptimizeAway(result.execution.dispatch_count);
    }
    return timer.read();
}

fn telemetry() backend_telemetry.BackendTelemetry {
    return .{
        .backend_id = .doe_vulkan,
        .backend_selection_reason = "dispatch-seam-benchmark",
        .fallback_used = false,
        .selection_policy_hash = "dispatch-seam-benchmark",
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .host_plan_artifact_path = null,
        .host_plan_artifact_hash = null,
        .adapter_ordinal = null,
        .queue_family_index = null,
        .present_capable = null,
    };
}
