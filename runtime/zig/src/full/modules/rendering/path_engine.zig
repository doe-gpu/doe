const std = @import("std");
const artifact = @import("../../../contracts/artifact.zig");

pub const MODULE_ID = "fawn_path_engine";

pub const FallbackReason = error{
    join_mode_unsupported,
    dash_pattern_unsupported,
    geometry_pathological,
    resource_budget_exceeded,
    runtime_unavailable,
    runtime_execute_failed,
};

pub const PathSegment = struct {
    segment: []const u8,
    points: []const [2]f64,
};

pub const StrokeState = struct {
    width: f64,
    joinMode: []const u8,
    capMode: []const u8,
    miterLimit: f64,
    dashPattern: []const f64,
};

pub const FillState = struct {
    fillRule: []const u8,
    opacity: f64,
};

pub const ClipState = struct {
    mode: []const u8,
};

pub const Target = struct {
    width: u32,
    height: u32,
};

pub const Request = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    pathStream: []const PathSegment,
    strokeState: StrokeState,
    fillState: FillState,
    clipState: ClipState,
    target: Target,
};

pub const PolicyBody = struct {
    allowedJoinModes: []const []const u8,
    allowDashPatterns: bool,
    maxSegments: u32,
    maxTargetPixels: u64,
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

pub const GeometryStats = struct {
    segmentCount: u32,
    tessellatedPrimitiveCount: u32,
};

pub const RasterStats = struct {
    passCount: u32,
    drawCallCount: u32,
};

pub const FallbackReasonHistogram = struct {
    join_mode_unsupported: u32 = 0,
    dash_pattern_unsupported: u32 = 0,
    geometry_pathological: u32 = 0,
    resource_budget_exceeded: u32 = 0,
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
    geometryStats: GeometryStats,
    rasterStats: RasterStats,
    fallbackStats: FallbackStats,
};

pub const Result = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    geometryStats: GeometryStats,
    rasterStats: RasterStats,
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
        FallbackReason.join_mode_unsupported => histogram.join_mode_unsupported += 1,
        FallbackReason.dash_pattern_unsupported => histogram.dash_pattern_unsupported += 1,
        FallbackReason.geometry_pathological => histogram.geometry_pathological += 1,
        FallbackReason.resource_budget_exceeded => histogram.resource_budget_exceeded += 1,
        FallbackReason.runtime_unavailable => histogram.runtime_unavailable += 1,
        FallbackReason.runtime_execute_failed => histogram.runtime_execute_failed += 1,
    }
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

    const segment_count: u32 = @intCast(request.pathStream.len);
    const tessellated_primitive_count: u32 = segment_count * 2;
    const draw_call_count: u32 = if (segment_count <= 1) 1 else (segment_count + 1) / 2;
    const target_pixels = @as(u64, request.target.width) * @as(u64, request.target.height);

    if (!contains(policy.policy.allowedJoinModes, request.strokeState.joinMode)) {
        addFallbackReason(&fallback_histogram, FallbackReason.join_mode_unsupported);
        fallback_count += 1;
    }
    if (request.strokeState.dashPattern.len > 0 and !policy.policy.allowDashPatterns) {
        addFallbackReason(&fallback_histogram, FallbackReason.dash_pattern_unsupported);
        fallback_count += 1;
    }
    if (segment_count > policy.policy.maxSegments) {
        addFallbackReason(&fallback_histogram, FallbackReason.geometry_pathological);
        fallback_count += 1;
    }
    if (target_pixels > policy.policy.maxTargetPixels) {
        addFallbackReason(&fallback_histogram, FallbackReason.resource_budget_exceeded);
        fallback_count += 1;
    }

    const effective_draw_call_count: u32 = if (fallback_count == 0) draw_call_count else 0;
    const payload = ResultNoTrace{
        .schemaVersion = 1,
        .moduleId = MODULE_ID,
        .artifactKind = "result",
        .geometryStats = .{
            .segmentCount = segment_count,
            .tessellatedPrimitiveCount = tessellated_primitive_count,
        },
        .rasterStats = .{
            .passCount = if (fallback_count == 0) 1 else 0,
            .drawCallCount = effective_draw_call_count,
        },
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
        .geometryStats = payload.geometryStats,
        .rasterStats = payload.rasterStats,
        .fallbackStats = payload.fallbackStats,
        .traceLink = .{
            .moduleIdentity = MODULE_ID,
            .requestHash = request_hash,
            .policyHash = policy_hash,
            .resultHash = result_hash,
        },
    };
}
