//! Unit tests verifying Hexagonal composition roots and evidence observation.

const std = @import("std");
const contracts = @import("../../src/contracts/mod.zig");
const backend = struct {
    pub fn ports() type {
        return @import("../../src/backend/ports/mod.zig");
    }
};
const evidence = @import("../../src/evidence/mod.zig");
const app = @import("../../src/app/mod.zig");
const execution = @import("../../src/runtime/execution.zig");

test "evidence: trace collector and hash chaining" {
    var collector = evidence.TraceCollector{};
    const rep = contracts.executionReport().ExecutionReport.success(.{
        .setup_ns = 10,
        .encode_ns = 20,
        .submit_wait_ns = 30,
    }, 1);

    const compute_op = contracts.preparedOperation().fromCommand(.{ .kernel_dispatch = .{
        .kernel = "fn main() {}",
        .x = 1,
        .y = 1,
        .z = 1,
    } }, 100).compute;

    const ev1 = collector.record(.{ .compute = compute_op }, rep, 1000);
    try std.testing.expectEqual(@as(u64, 0), ev1.seq);
    try std.testing.expectEqual(@as(u64, 100), ev1.operation_id);

    const ev2 = collector.record(.{ .compute = compute_op }, rep, 2000);
    try std.testing.expectEqual(@as(u64, 1), ev2.seq);
    try std.testing.expectEqualSlices(u8, &ev1.hash, &ev2.previous_hash);
}

test "evidence: oracle comparisons and replay validation" {
    const b1 = [_]u8{ 1, 2, 3, 4 };
    const b2 = [_]u8{ 1, 2, 3, 4 };
    const exact_res = evidence.compareExactBytes(&b1, &b2);
    try std.testing.expect(exact_res.passed);

    const f1 = [_]f32{ 1.0, 2.0, 3.0 };
    const f2 = [_]f32{ 1.0001, 2.0001, 2.9999 };
    const tol_res = evidence.compareFloatsWithTolerance(&f1, &f2, .{
        .atol = 1e-3,
        .rtol = 1e-2,
        .max_divergent_elements = 0,
    });
    try std.testing.expect(tol_res.passed);

    const hashes1 = [_]contracts.identity().Sha256Digest{ [_]u8{1} ** 32, [_]u8{2} ** 32 };
    const hashes2 = [_]contracts.identity().Sha256Digest{ [_]u8{1} ** 32, [_]u8{2} ** 32 };
    const replay_res = evidence.validateReplayHashes(&hashes1, &hashes2);
    try std.testing.expect(replay_res.matched);
}

test "production execution context prepares, observes, and routes every domain" {
    // Mock ComputePort
    const MockCompute = struct {
        fn execute(ctx: *anyopaque, compute_op: contracts.preparedOperation().PreparedComputeOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = compute_op;
            return contracts.executionReport().ExecutionReport.success(.{
                .setup_ns = 15,
                .encode_ns = 35,
                .submit_wait_ns = 55,
            }, 1);
        }
        fn prewarm(ctx: *anyopaque, kernel: []const u8, entry_point: ?[]const u8, bindings: ?[]const contracts.model.computeTypes().KernelBinding, initialize: bool) anyerror!void {
            _ = ctx;
            _ = kernel;
            _ = entry_point;
            _ = bindings;
            _ = initialize;
        }
        fn timestampMode(ctx: *anyopaque, mode: contracts.runtimeConfiguration().GpuTimestampMode) void {
            _ = ctx;
            _ = mode;
        }
    };
    const compute_vt = backend.ports().ComputePortVTable{
        .execute_compute = MockCompute.execute,
        .prewarm_kernel = MockCompute.prewarm,
        .set_gpu_timestamp_mode = MockCompute.timestampMode,
    };
    var dummy_ctx: u8 = 0;
    const c_port = backend.ports().ComputePort{
        .context = &dummy_ctx,
        .vtable = &compute_vt,
    };

    // Mock TransferPort
    const MockTransfer = struct {
        fn execute(ctx: *anyopaque, transfer_op: contracts.preparedOperation().PreparedTransferOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = transfer_op;
            return contracts.executionReport().ExecutionReport.success(.{
                .setup_ns = 5,
                .encode_ns = 10,
                .submit_wait_ns = 15,
            }, 0);
        }
        fn prewarm(ctx: *anyopaque, max_upload_bytes: u64) anyerror!void {
            _ = ctx;
            _ = max_upload_bytes;
        }
        fn uploadBehavior(ctx: *anyopaque, mode: contracts.runtimeConfiguration().UploadBufferUsageMode, submit_every: u32) void {
            _ = ctx;
            _ = mode;
            _ = submit_every;
        }
    };
    const transfer_vt = backend.ports().TransferPortVTable{
        .execute_transfer = MockTransfer.execute,
        .prewarm_upload = MockTransfer.prewarm,
        .set_upload_behavior = MockTransfer.uploadBehavior,
    };
    const t_port = backend.ports().TransferPort{
        .context = &dummy_ctx,
        .vtable = &transfer_vt,
    };

    // Mock QueuePort
    const MockQueue = struct {
        fn flush(ctx: *anyopaque) anyerror!u64 {
            _ = ctx;
            return 1;
        }
        fn sync(ctx: *anyopaque) anyerror!void {
            _ = ctx;
        }
        fn waitMode(ctx: *anyopaque, mode: contracts.runtimeConfiguration().QueueWaitMode) void {
            _ = ctx;
            _ = mode;
        }
        fn waitTimeout(ctx: *anyopaque, timeout_ns: u64) void {
            _ = ctx;
            _ = timeout_ns;
        }
        fn syncMode(ctx: *anyopaque, mode: contracts.runtimeConfiguration().QueueSyncMode) void {
            _ = ctx;
            _ = mode;
        }
    };
    const queue_vt = backend.ports().QueuePortVTable{
        .flush = MockQueue.flush,
        .sync = MockQueue.sync,
        .set_wait_mode = MockQueue.waitMode,
        .set_wait_timeout_ns = MockQueue.waitTimeout,
        .set_sync_mode = MockQueue.syncMode,
    };
    const q_port = backend.ports().QueuePort{
        .context = &dummy_ctx,
        .vtable = &queue_vt,
    };

    // Mock ReadbackPort
    const MockReadback = struct {
        fn capture(ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8 {
            _ = ctx;
            _ = handle;
            _ = offset;
            return allocator.alloc(u8, size);
        }
    };
    const readback_vt = backend.ports().ReadbackPortVTable{
        .capture_buffer = MockReadback.capture,
    };
    const r_port = backend.ports().ReadbackPort{
        .context = &dummy_ctx,
        .vtable = &readback_vt,
    };

    // Mock TelemetryPort
    const MockTelemetry = struct {
        fn getTimestamp(ctx: *anyopaque) anyerror!u64 {
            _ = ctx;
            return 123456789;
        }
        fn snapshot(ctx: *anyopaque) contracts.runtimeTelemetry().RuntimeTelemetry {
            _ = ctx;
            return contracts.runtimeTelemetry().defaultTelemetry();
        }
    };
    const telemetry_vt = backend.ports().TelemetryPortVTable{
        .get_gpu_timestamp_ns = MockTelemetry.getTimestamp,
        .snapshot = MockTelemetry.snapshot,
    };
    const tel_port = backend.ports().TelemetryPort{
        .context = &dummy_ctx,
        .vtable = &telemetry_vt,
    };

    // Mock RenderPort
    const MockRender = struct {
        fn execute(ctx: *anyopaque, op: contracts.preparedOperation().PreparedRenderOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = op;
            return contracts.executionReport().ExecutionReport.success(.{}, 0);
        }
    };
    const render_vt = backend.ports().RenderPortVTable{
        .execute_render = MockRender.execute,
    };
    const ren_port = backend.ports().RenderPort{
        .context = &dummy_ctx,
        .vtable = &render_vt,
    };

    // Mock SpatialPort
    const MockSpatial = struct {
        fn execute(ctx: *anyopaque, op: contracts.spatialOperation().PreparedSpatialOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = op;
            return contracts.executionReport().ExecutionReport.success(.{}, 0);
        }
    };
    const spatial_vt = backend.ports().SpatialPortVTable{
        .execute_spatial = MockSpatial.execute,
    };
    const spa_port = backend.ports().SpatialPort{
        .context = &dummy_ctx,
        .vtable = &spatial_vt,
    };

    const MockResource = struct {
        fn execute(ctx: *anyopaque, op: contracts.preparedOperation().PreparedResourceOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = op;
            return contracts.executionReport().ExecutionReport.success(.{}, 0);
        }
    };
    const resource_vt = backend.ports().ResourcePortVTable{ .execute_resource = MockResource.execute };
    const resource = backend.ports().ResourcePort{ .context = &dummy_ctx, .vtable = &resource_vt };

    const MockSurface = struct {
        fn execute(ctx: *anyopaque, op: contracts.preparedOperation().PreparedSurfaceOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = op;
            return contracts.executionReport().ExecutionReport.success(.{}, 0);
        }
    };
    const surface_vt = backend.ports().SurfacePortVTable{ .execute_surface = MockSurface.execute };
    const surface = backend.ports().SurfacePort{ .context = &dummy_ctx, .vtable = &surface_vt };

    const MockLifecycle = struct {
        fn execute(ctx: *anyopaque, op: contracts.preparedOperation().PreparedLifecycleOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = op;
            return contracts.executionReport().ExecutionReport.success(.{}, 0);
        }
    };
    const lifecycle_vt = backend.ports().LifecyclePortVTable{ .execute_lifecycle = MockLifecycle.execute };
    const lifecycle = backend.ports().LifecyclePort{ .context = &dummy_ctx, .vtable = &lifecycle_vt };

    var trace_collector = evidence.TraceCollector{};
    const ev_port = trace_collector.asEvidencePort();

    const ports = backend.ports().PortBundle{
        .id = .doe_metal,
        .compute = c_port,
        .transfer = t_port,
        .queue = q_port,
        .readback = r_port,
        .telemetry = tel_port,
        .render = ren_port,
        .resource = resource,
        .surface = surface,
        .lifecycle = lifecycle,
        .spatial = spa_port,
    };

    var production_context = execution.ExecutionContext.initNative(.metal_doe_app, ports);
    defer production_context.deinit();
    production_context.setEvidenceObserver(ev_port);

    const compute_result = try production_context.execute(.{ .kernel_dispatch = .{
        .kernel = "fn main() {}",
        .x = 1,
        .y = 1,
        .z = 1,
    } });
    try std.testing.expectEqual(execution.ExecutionStatus.ok, compute_result.status);
    try std.testing.expectEqual(@as(u64, 1), trace_collector.event_count);

    const data = [_]u8{ 5, 6, 7, 8 };
    const transfer_result = try production_context.execute_buffer_write_bytes_with_semantic(
        202,
        0,
        data.len,
        &data,
        .{},
    );
    try std.testing.expectEqual(execution.ExecutionStatus.ok, transfer_result.status);
    try std.testing.expectEqual(@as(u64, 2), trace_collector.event_count);

    const production_result = try production_context.execute(.{ .surface_present = .{ .handle = 303 } });
    try std.testing.expectEqual(execution.ExecutionStatus.ok, production_result.status);
    try std.testing.expectEqual(@as(u64, 3), trace_collector.event_count);

    var trace_context = execution.ExecutionContext.initTrace(.metal_doe_app);
    defer trace_context.deinit();
    trace_context.setEvidenceObserver(ev_port);
    const trace_result = try trace_context.execute(.{ .barrier = .{ .dependency_count = 1 } });
    try std.testing.expectEqual(execution.ExecutionStatus.skipped, trace_result.status);
    try std.testing.expectEqual(@as(u64, 4), trace_collector.event_count);

    const FailingCompute = struct {
        fn execute(ctx: *anyopaque, op: contracts.preparedOperation().PreparedComputeOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = op;
            return error.ExpectedExecutionFailure;
        }
    };
    const failing_compute_vt = backend.ports().ComputePortVTable{
        .execute_compute = FailingCompute.execute,
        .prewarm_kernel = MockCompute.prewarm,
        .set_gpu_timestamp_mode = MockCompute.timestampMode,
    };
    var failing_ports = ports;
    failing_ports.compute = .{
        .context = &dummy_ctx,
        .vtable = &failing_compute_vt,
    };
    var failing_context = execution.ExecutionContext.initNative(.metal_doe_app, failing_ports);
    defer failing_context.deinit();
    failing_context.setEvidenceObserver(ev_port);
    const failure_result = try failing_context.execute(.{ .barrier = .{ .dependency_count = 0 } });
    try std.testing.expectEqual(execution.ExecutionStatus.@"error", failure_result.status);
    try std.testing.expectEqual(@as(u64, 5), trace_collector.event_count);
}
