//! Unit tests verifying Hexagonal composition roots and evidence observation.

const std = @import("std");
const contracts = @import("../../src/contracts/mod.zig");
const backend = @import("../../src/backend/mod.zig");
const evidence = @import("../../src/evidence/mod.zig");
const composition = @import("../../src/composition/mod.zig");
const app = @import("../../src/app/mod.zig");

test "evidence: trace collector and hash chaining" {
    var collector = evidence.TraceCollector{};
    const rep = contracts.executionReport().ExecutionReport.success(.{
        .setup_ns = 10,
        .encode_ns = 20,
        .submit_wait_ns = 30,
    }, 1);

    const compute_op = contracts.preparedOperation().PreparedComputeOperation{
        .operation_id = 100,
        .kernel_source = "fn main() {}",
        .workgroups = .{ .x = 1, .y = 1, .z = 1 },
    };

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

test "composition: runtime composition and CLI/native execution roots" {
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
    };
    const compute_vt = backend.ports().ComputePortVTable{
        .execute_compute = MockCompute.execute,
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
    };
    const transfer_vt = backend.ports().TransferPortVTable{
        .execute_transfer = MockTransfer.execute,
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
    };
    const queue_vt = backend.ports().QueuePortVTable{
        .flush = MockQueue.flush,
        .sync = MockQueue.sync,
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
    };
    const telemetry_vt = backend.ports().TelemetryPortVTable{
        .get_gpu_timestamp_ns = MockTelemetry.getTimestamp,
    };
    const tel_port = backend.ports().TelemetryPort{
        .context = &dummy_ctx,
        .vtable = &telemetry_vt,
    };

    // Mock RenderPort
    const MockRender = struct {
        fn executePass(ctx: *anyopaque, op: contracts.renderCommand().PreparedRenderPassOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = op;
            return contracts.executionReport().ExecutionReport.success(.{}, 0);
        }
        fn createPipe(ctx: *anyopaque, op: contracts.renderCommand().PreparedPipelineOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            _ = op;
            return contracts.executionReport().ExecutionReport.success(.{}, 0);
        }
    };
    const render_vt = backend.ports().RenderPortVTable{
        .execute_render_pass = MockRender.executePass,
        .create_pipeline = MockRender.createPipe,
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

    var trace_collector = evidence.TraceCollector{};
    const ev_port = trace_collector.asEvidencePort();

    const runtime_comp = composition.RuntimeComposition{
        .ports = .{
            .id = .doe_metal,
            .compute = c_port,
            .transfer = t_port,
            .queue = q_port,
            .readback = r_port,
            .telemetry = tel_port,
            .render = ren_port,
            .spatial = spa_port,
        },
        .evidence = ev_port,
    };

    // Execute via CLI composition
    const cli_res = try composition.executeComputeCli(runtime_comp, .{
        .kernel_source = "fn main() {}",
        .workgroups = .{ .x = 1, .y = 1, .z = 1 },
    }, 77);
    try std.testing.expect(cli_res.status.isSuccess());
    try std.testing.expectEqual(@as(u64, 105), cli_res.timing.totalWallNs());
    try std.testing.expectEqual(@as(u64, 1), trace_collector.event_count);

    // Execute via Dropin composition
    const data = [_]u8{ 5, 6, 7, 8 };
    const dropin_res = try composition.executeDropinWriteBuffer(runtime_comp, 202, 0, data.len, &data, 88);
    try std.testing.expect(dropin_res.status.isSuccess());
    try std.testing.expectEqual(@as(u64, 30), dropin_res.timing.totalWallNs());
    try std.testing.expectEqual(@as(u64, 2), trace_collector.event_count);
}
