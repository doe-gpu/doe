//! Unit tests verifying Hexagonal Architecture contracts, narrow ports, and application orchestration.

const std = @import("std");
const contracts = @import("../../src/contracts/mod.zig");
const backend = struct {
    pub fn ports() type {
        return @import("../../src/backend/ports/mod.zig");
    }
};
const app = @import("../../src/app/mod.zig");

test "hexagonal contracts: identity, execution report, and exactness" {
    const identity_mod = contracts.identity();
    const prog_id = identity_mod.ProgramIdentity{
        .source_sha256 = [_]u8{1} ** 32,
        .lowered_sha256 = [_]u8{2} ** 32,
        .entry_point = "main",
    };
    try std.testing.expect(!prog_id.isNull());

    const hex_str = identity_mod.formatHexDigest(prog_id.source_sha256);
    try std.testing.expectEqual(@as(usize, 64), hex_str.len);

    const report_mod = contracts.executionReport();
    const rep = report_mod.ExecutionReport.success(.{
        .setup_ns = 100,
        .encode_ns = 200,
        .submit_wait_ns = 300,
    }, 1);
    try std.testing.expect(rep.status.isSuccess());
    try std.testing.expectEqual(@as(u64, 600), rep.timing.totalWallNs());
    try std.testing.expectEqual(@as(u32, 1), rep.dispatch_count);
    try std.testing.expectEqual(@as(u32, 1), rep.submit_count);

    const exactness_mod = contracts.exactness();
    const oracle_res = exactness_mod.OracleResult{
        .passed = true,
        .exactness_class = .exact_bitwise,
        .max_absolute_error = 0.0,
    };
    try std.testing.expect(oracle_res.passed);
}

test "hexagonal application layer: prepare and execute compute" {
    const req = app.ComputeRequest{
        .kernel_source = "@compute @workgroup_size(1) fn main() {}",
        .entry_point = "main",
        .workgroups = .{ .x = 1, .y = 1, .z = 1 },
    };

    const op = app.prepareCompute(req, 42);
    try std.testing.expectEqual(@as(u64, 42), op.operation_id);
    try std.testing.expectEqualStrings("main", op.operation.kernel_dispatch.entry_point.?);
    try std.testing.expectEqual(@as(u32, 1), op.operation.kernel_dispatch.x);

    // Mock ComputePort
    const MockCompute = struct {
        fn execute(ctx: *anyopaque, compute_op: contracts.preparedOperation().PreparedComputeOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            try std.testing.expectEqual(@as(u64, 42), compute_op.operation_id);
            return contracts.executionReport().ExecutionReport.success(.{
                .setup_ns = 50,
                .encode_ns = 150,
                .submit_wait_ns = 250,
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
    const vtable = backend.ports().ComputePortVTable{
        .execute_compute = MockCompute.execute,
        .prewarm_kernel = MockCompute.prewarm,
        .set_gpu_timestamp_mode = MockCompute.timestampMode,
    };
    var dummy_ctx: u8 = 0;
    const port = backend.ports().ComputePort{
        .context = &dummy_ctx,
        .vtable = &vtable,
    };

    const result = try app.executeCompute(port, op);
    try std.testing.expect(result.status.isSuccess());
    try std.testing.expectEqual(@as(u64, 450), result.timing.totalWallNs());
}

test "hexagonal application layer: prepare and execute transfer" {
    const data = [_]u8{ 1, 2, 3, 4 };
    const req = app.TransferRequest{
        .buffer_handle = 101,
        .offset_bytes = 0,
        .size_bytes = data.len,
        .data = &data,
    };

    const op = app.prepareTransfer(req, 99);
    try std.testing.expectEqual(@as(u64, 99), op.operation_id);
    try std.testing.expectEqual(@as(u64, 101), op.operation.direct_buffer_write.handle);

    // Mock TransferPort
    const MockTransfer = struct {
        fn execute(ctx: *anyopaque, transfer_op: contracts.preparedOperation().PreparedTransferOperation) anyerror!contracts.executionReport().ExecutionReport {
            _ = ctx;
            try std.testing.expectEqual(@as(u64, 99), transfer_op.operation_id);
            try std.testing.expectEqual(@as(u64, 4), transfer_op.operation.direct_buffer_write.buffer_size);
            return contracts.executionReport().ExecutionReport.success(.{
                .setup_ns = 10,
                .encode_ns = 20,
                .submit_wait_ns = 30,
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
    const vtable = backend.ports().TransferPortVTable{
        .execute_transfer = MockTransfer.execute,
        .prewarm_upload = MockTransfer.prewarm,
        .set_upload_behavior = MockTransfer.uploadBehavior,
    };
    var dummy_ctx: u8 = 0;
    const port = backend.ports().TransferPort{
        .context = &dummy_ctx,
        .vtable = &vtable,
    };

    const result = try app.executeTransfer(port, op);
    try std.testing.expect(result.status.isSuccess());
    try std.testing.expectEqual(@as(u64, 60), result.timing.totalWallNs());
}

test "optimization and learning contracts: profile, policy, and promotion" {
    const wp_mod = contracts.workloadProfile();
    const profile = wp_mod.WorkloadProfile{
        .name = "fawn_agent_interactive",
        .domain = .agent_browser_interactive,
        .priority = .interactive_lowest_latency,
        .memory_budget = .{ .working_set_max_mb = 512, .cache_pool_max_mb = 128 },
    };
    try std.testing.expectEqual(wp_mod.ExecutionDomain.agent_browser_interactive, profile.domain);
    try std.testing.expectEqual(wp_mod.LatencyPriority.interactive_lowest_latency, profile.priority);

    const spec_mod = contracts.specializationPolicy();
    const candidate = spec_mod.OptimizationCandidate{
        .id = "opt_clamp_elision_fawn_v1",
        .kind = .robustness_clamp_elision,
        .enabled_by_default = true,
    };
    try std.testing.expectEqual(spec_mod.OptimizationKind.robustness_clamp_elision, candidate.kind);

    const promo_mod = contracts.promotionReceipt();
    const receipt = promo_mod.PromotionReceipt{
        .candidate_id = "opt_clamp_elision_fawn_v1",
        .disposition = .promoted_faster_and_exact,
        .hardware_adapter_id = "apple-metal-m3-max",
        .baseline_p50_ns = 1000,
        .candidate_p50_ns = 650,
        .oracle_verdict = .{ .passed = true, .exactness_class = .exact_bitwise },
        .source_tree_sha256 = [_]u8{0xab} ** 32,
        .timestamp_unix_sec = 1771740000,
    };
    try std.testing.expect(receipt.isPromoted());
}

test "hexagonal evidence requirement remains a domain contract" {
    const ev_mod = contracts.evidenceContract();
    const req_ev = ev_mod.EvidenceRequirement{
        .disposition = .execution_receipt_required,
        .record_gpu_timestamps = true,
    };
    try std.testing.expectEqual(ev_mod.EvidenceDisposition.execution_receipt_required, req_ev.disposition);
}
