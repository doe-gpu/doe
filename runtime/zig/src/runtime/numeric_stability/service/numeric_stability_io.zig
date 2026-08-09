const std = @import("std");
const artifact = @import("../../../contracts/artifact.zig");
const trace_numeric_stability = @import("../trace_meta.zig");
const types = @import("numeric_stability_types.zig");

pub fn ensureParentPath(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_name| {
        if (dir_name.len == 0) return;
        try std.fs.cwd().makePath(dir_name);
    }
}

pub fn buildDecisionCounts(route_decision: []const u8) trace_numeric_stability.TraceNumericStabilityDecisionCounts {
    var counts = trace_numeric_stability.TraceNumericStabilityDecisionCounts{};
    if (std.mem.eql(u8, route_decision, "accept-fast")) {
        counts.accept_fast = 1;
    } else if (std.mem.eql(u8, route_decision, "prefer-stable")) {
        counts.prefer_stable = 1;
    } else if (std.mem.eql(u8, route_decision, "abstain")) {
        counts.abstain = 1;
    }
    return counts;
}

pub fn writeReceiptJsonl(
    allocator: std.mem.Allocator,
    receipt_path: []const u8,
    receipt: types.Receipt,
) !void {
    try ensureParentPath(receipt_path);
    const payload = try artifact.jsonStringifyAlloc(allocator, receipt);
    defer allocator.free(payload);
    const file = try std.fs.cwd().createFile(receipt_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(payload);
    try file.writeAll("\n");
}

pub fn writeTraceMetaJson(
    allocator: std.mem.Allocator,
    trace_meta_path: []const u8,
    summary: trace_numeric_stability.TraceNumericStabilitySummary,
) !void {
    const hashless = types.HashlessTraceMeta{
        .traceVersion = 1,
        .module = types.MODULE_ID,
        .seqMax = 0,
        .rowCount = 0,
        .numericStability = summary,
    };
    const hash_hex = try artifact.stableHashJsonAlloc(allocator, hashless);
    defer allocator.free(hash_hex);
    const hash_value = try std.fmt.allocPrint(allocator, "sha256:{s}", .{hash_hex});
    defer allocator.free(hash_value);
    const meta = types.TraceMetaFile{
        .traceVersion = hashless.traceVersion,
        .module = hashless.module,
        .seqMax = hashless.seqMax,
        .rowCount = hashless.rowCount,
        .hash = hash_value,
        .previousHash = types.ZERO_HASH,
        .numericStability = hashless.numericStability,
    };
    try ensureParentPath(trace_meta_path);
    const payload = try artifact.jsonStringifyAlloc(allocator, meta);
    defer allocator.free(payload);
    const file = try std.fs.cwd().createFile(trace_meta_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(payload);
    try file.writeAll("\n");
}
