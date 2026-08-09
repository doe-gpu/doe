const std = @import("std");
const artifact = @import("../../../contracts/artifact.zig");

pub const MODULE_ID = "fawn_effects_pipeline";

pub const FallbackReason = error{
    effect_op_unsupported,
    color_space_mode_unsupported,
    intermediate_budget_exceeded,
    runtime_unavailable,
    runtime_execute_failed,
};

pub const EffectNode = struct {
    nodeId: []const u8,
    op: []const u8,
    params: std.json.Value = .null,
};

pub const InputSurface = struct {
    surfaceId: []const u8,
    bytes: u64,
};

pub const ExecutionPolicy = struct {
    precisionClass: []const u8,
    colorSpace: []const u8,
};

pub const Target = struct {
    width: u32,
    height: u32,
    format: []const u8,
};

pub const Request = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    effectGraph: []const EffectNode,
    inputs: []const InputSurface,
    executionPolicy: ExecutionPolicy,
    target: Target,
};

pub const PolicyBody = struct {
    allowedOps: []const []const u8,
    allowedColorSpaces: []const []const u8,
    maxNodeCount: u32,
    maxIntermediateBytes: u64,
};

pub const Policy = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    version: u32,
    promotedFromNursery: bool,
    promotedAt: []const u8,
    policy: PolicyBody,
};

pub const OutputArtifact = struct {
    artifactId: []const u8,
};

pub const ExecutionStats = struct {
    nodeCount: u32,
    passCount: u32,
    temporaryBytes: u64,
};

pub const TimingStats = struct {
    setupNs: u64,
    encodeNs: u64,
    submitWaitNs: u64,
};

pub const FallbackReasonHistogram = struct {
    effect_op_unsupported: u32 = 0,
    color_space_mode_unsupported: u32 = 0,
    intermediate_budget_exceeded: u32 = 0,
    runtime_unavailable: u32 = 0,
    runtime_execute_failed: u32 = 0,
};

pub const FallbackStats = struct {
    fallbackCount: u32,
    fallbackReasonHistogram: FallbackReasonHistogram,
};

pub const ResultNoTrace = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    outputArtifact: OutputArtifact,
    executionStats: ExecutionStats,
    timingStats: TimingStats,
    fallbackStats: FallbackStats,
};

pub const Result = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    outputArtifact: OutputArtifact,
    executionStats: ExecutionStats,
    timingStats: TimingStats,
    fallbackStats: FallbackStats,
    traceLink: artifact.TraceLink,
};

pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Request) {
    return try std.json.parseFromSlice(Request, allocator, bytes, .{ .ignore_unknown_fields = false });
}

pub fn parsePolicy(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Policy) {
    return try std.json.parseFromSlice(Policy, allocator, bytes, .{ .ignore_unknown_fields = false });
}

fn ensureValidRequest(request: Request) !void {
    if (!std.mem.eql(u8, request.moduleId, MODULE_ID)) return error.InvalidModuleId;
    if (!std.mem.eql(u8, request.artifactKind, "request")) return error.InvalidArtifactKind;
}

fn ensureValidPolicy(policy: Policy) !void {
    if (!std.mem.eql(u8, policy.moduleId, MODULE_ID)) return error.InvalidModuleId;
    if (!std.mem.eql(u8, policy.artifactKind, "policy")) return error.InvalidArtifactKind;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn addFallbackReason(histogram: *FallbackReasonHistogram, reason: FallbackReason) void {
    switch (reason) {
        FallbackReason.effect_op_unsupported => histogram.effect_op_unsupported += 1,
        FallbackReason.color_space_mode_unsupported => histogram.color_space_mode_unsupported += 1,
        FallbackReason.intermediate_budget_exceeded => histogram.intermediate_budget_exceeded += 1,
        FallbackReason.runtime_unavailable => histogram.runtime_unavailable += 1,
        FallbackReason.runtime_execute_failed => histogram.runtime_execute_failed += 1,
    }
}

fn totalInputBytes(request: Request) u64 {
    var total: u64 = 0;
    for (request.inputs) |entry| total += entry.bytes;
    return total;
}

fn deterministicTiming(node_count: u32, pass_count: u32) TimingStats {
    return .{
        .setupNs = 8_000 + @as(u64, node_count) * 400,
        .encodeNs = 7_000 + @as(u64, pass_count) * 700,
        .submitWaitNs = 3_000 + @as(u64, pass_count) * 500,
    };
}

pub fn execute(allocator: std.mem.Allocator, request: Request, policy: Policy) !Result {
    try ensureValidRequest(request);
    try ensureValidPolicy(policy);

    const request_hash = try artifact.stableHashJsonAlloc(allocator, request);
    errdefer allocator.free(request_hash);
    const policy_hash = try artifact.stableHashJsonAlloc(allocator, policy);
    errdefer allocator.free(policy_hash);

    var fallback_histogram = FallbackReasonHistogram{};
    var fallback_count: u32 = 0;

    const node_count: u32 = @intCast(request.effectGraph.len);
    const pass_count: u32 = if (node_count == 0) 1 else node_count;
    const temporary_bytes = totalInputBytes(request) * @as(u64, @max(pass_count, 1));

    if (node_count > policy.policy.maxNodeCount) {
        addFallbackReason(&fallback_histogram, FallbackReason.effect_op_unsupported);
        fallback_count += 1;
    }
    if (!contains(policy.policy.allowedColorSpaces, request.executionPolicy.colorSpace)) {
        addFallbackReason(&fallback_histogram, FallbackReason.color_space_mode_unsupported);
        fallback_count += 1;
    }
    for (request.effectGraph) |node| {
        if (!contains(policy.policy.allowedOps, node.op)) {
            addFallbackReason(&fallback_histogram, FallbackReason.effect_op_unsupported);
            fallback_count += 1;
            break;
        }
    }
    if (temporary_bytes > policy.policy.maxIntermediateBytes) {
        addFallbackReason(&fallback_histogram, FallbackReason.intermediate_budget_exceeded);
        fallback_count += 1;
    }

    const effective_pass_count: u32 = if (fallback_count == 0) pass_count else 0;
    const payload = ResultNoTrace{
        .schemaVersion = 1,
        .moduleId = MODULE_ID,
        .artifactKind = "result",
        .outputArtifact = .{ .artifactId = try std.fmt.allocPrint(allocator, "effects://{s}", .{request_hash[0..16]}) },
        .executionStats = .{
            .nodeCount = node_count,
            .passCount = effective_pass_count,
            .temporaryBytes = temporary_bytes,
        },
        .timingStats = deterministicTiming(node_count, pass_count),
        .fallbackStats = .{
            .fallbackCount = fallback_count,
            .fallbackReasonHistogram = fallback_histogram,
        },
    };
    const result_hash = try artifact.stableHashJsonAlloc(allocator, payload);
    return .{
        .schemaVersion = payload.schemaVersion,
        .moduleId = payload.moduleId,
        .artifactKind = payload.artifactKind,
        .outputArtifact = payload.outputArtifact,
        .executionStats = payload.executionStats,
        .timingStats = payload.timingStats,
        .fallbackStats = payload.fallbackStats,
        .traceLink = .{
            .moduleIdentity = MODULE_ID,
            .requestHash = request_hash,
            .policyHash = policy_hash,
            .resultHash = result_hash,
        },
    };
}
