//! Evidence trace observer adapter recording hash-chained execution events.

const std = @import("std");
const prepared = @import("../contracts/prepared_operation.zig");
const report = @import("../contracts/execution_report.zig");
const identity = @import("../contracts/identity.zig");
const port = @import("port.zig");

pub const TraceEvent = struct {
    seq: u64,
    operation_id: u64,
    status: report.ExecutionStatus,
    timestamp_mono_ns: u64,
    hash: identity.Sha256Digest,
    previous_hash: identity.Sha256Digest,
};

pub const TraceCollector = struct {
    last_hash: identity.Sha256Digest = [_]u8{0} ** 32,
    event_count: u64 = 0,

    pub fn record(self: *TraceCollector, op: prepared.PreparedOperation, rep: report.ExecutionReport, timestamp_ns: u64) TraceEvent {
        const op_id = op.operationId();

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&self.last_hash);
        hasher.update(std.mem.asBytes(&self.event_count));
        hasher.update(std.mem.asBytes(&op_id));
        var event_hash: identity.Sha256Digest = undefined;
        hasher.final(&event_hash);

        const event = TraceEvent{
            .seq = self.event_count,
            .operation_id = op_id,
            .status = rep.status,
            .timestamp_mono_ns = timestamp_ns,
            .hash = event_hash,
            .previous_hash = self.last_hash,
        };

        self.last_hash = event_hash;
        self.event_count += 1;
        return event;
    }

    pub fn asEvidencePort(self: *TraceCollector) port.EvidencePort {
        const Bridge = struct {
            fn onPrepared(ctx: *anyopaque, op: prepared.PreparedOperation) void {
                _ = ctx;
                _ = op;
            }
            fn onCompleted(ctx: *anyopaque, op: prepared.PreparedOperation, rep: report.ExecutionReport) void {
                const collector: *TraceCollector = @ptrCast(@alignCast(ctx));
                _ = collector.record(op, rep, 0);
            }
        };
        const vtable = struct {
            const vt: port.EvidencePortVTable = .{
                .on_operation_prepared = Bridge.onPrepared,
                .on_operation_completed = Bridge.onCompleted,
            };
        };
        return .{
            .context = self,
            .vtable = &vtable.vt,
        };
    }
};
