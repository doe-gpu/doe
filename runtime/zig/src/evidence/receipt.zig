//! Execution receipt generator adapter binding operations to cryptographic proof.

const std = @import("std");
const prepared = @import("../contracts/prepared_operation.zig");
const report = @import("../contracts/execution_report.zig");
const identity = @import("../contracts/identity.zig");

pub const ExecutionReceipt = struct {
    receipt_version: u32 = 1,
    operation_id: u64,
    status: report.ExecutionStatus,
    timing_total_ns: u64,
    dispatch_count: u32,
    source_sha256: identity.Sha256Digest,
};

pub fn createExecutionReceipt(op: prepared.PreparedOperation, rep: report.ExecutionReport) ExecutionReceipt {
    const op_id = op.operationId();
    const src_sha: identity.Sha256Digest = switch (op) {
        .compute => |c| c.identity.program.source_sha256,
        .spatial => |s| s.program_identity.source_sha256,
        else => [_]u8{0} ** 32,
    };

    return .{
        .operation_id = op_id,
        .status = rep.status,
        .timing_total_ns = rep.timing.totalWallNs(),
        .dispatch_count = rep.dispatch_count,
        .source_sha256 = src_sha,
    };
}
