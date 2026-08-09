const std = @import("std");
const artifact = @import("../../../contracts/artifact.zig");

pub const MODULE_ID = "fawn_2d_sdf_renderer";

pub const FallbackReason = error{
    unsupported_blend_mode,
    unsupported_clip_mode,
    required_capability_missing,
    path_complexity_exceeded,
    resource_budget_exceeded,
    runtime_unavailable,
    runtime_execute_failed,
};

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const TextRun = struct {
    fontKey: []const u8,
    fontPx: f64 = 0,
    glyphIds: []const u32,
    positions: []const Point,
    color: [4]u8,
    transform: [6]f64,
};

pub const PathOp = struct {
    op: []const u8,
    points: []const Point,
};

pub const PaintClipState = struct {
    mode: []const u8,
    bounds: ?[4]f64 = null,
};

pub const PaintState = struct {
    blendMode: []const u8,
    clipState: PaintClipState,
    transform: [6]f64,
};

pub const Target = struct {
    width: u32,
    height: u32,
    format: []const u8,
    sampleCount: u32,
};

pub const Request = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    textRuns: []const TextRun,
    pathOps: []const PathOp,
    paintState: PaintState,
    target: Target,
};

pub const PolicyBody = struct {
    allowedBlendModes: []const []const u8,
    allowedClipModes: []const []const u8,
    allowedSampleCounts: []const u32,
    atlasGlyphCapacity: u32,
    maxPathOps: u32,
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

pub const RenderArtifact = struct {
    artifactId: []const u8,
};

pub const RenderStats = struct {
    drawCallCount: u32,
    atlasHitCount: u32,
    atlasMissCount: u32,
    passCount: u32,
};

pub const TimingStats = struct {
    setupNs: u64,
    encodeNs: u64,
    submitWaitNs: u64,
};

pub const FallbackReasonHistogram = struct {
    unsupported_blend_mode: u32 = 0,
    unsupported_clip_mode: u32 = 0,
    required_capability_missing: u32 = 0,
    path_complexity_exceeded: u32 = 0,
    resource_budget_exceeded: u32 = 0,
    runtime_unavailable: u32 = 0,
    runtime_execute_failed: u32 = 0,
};

pub const QualityStats = struct {
    fallbackCount: u32,
    fallbackReasonHistogram: FallbackReasonHistogram,
};

pub const ResultNoTrace = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    renderArtifact: RenderArtifact,
    renderStats: RenderStats,
    timingStats: TimingStats,
    qualityStats: QualityStats,
};

pub const Result = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    renderArtifact: RenderArtifact,
    renderStats: RenderStats,
    timingStats: TimingStats,
    qualityStats: QualityStats,
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

fn containsStrings(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn containsU32(values: []const u32, needle: u32) bool {
    for (values) |value| {
        if (value == needle) return true;
    }
    return false;
}

fn addFallbackReason(histogram: *FallbackReasonHistogram, reason: FallbackReason) void {
    switch (reason) {
        FallbackReason.unsupported_blend_mode => histogram.unsupported_blend_mode += 1,
        FallbackReason.unsupported_clip_mode => histogram.unsupported_clip_mode += 1,
        FallbackReason.required_capability_missing => histogram.required_capability_missing += 1,
        FallbackReason.path_complexity_exceeded => histogram.path_complexity_exceeded += 1,
        FallbackReason.resource_budget_exceeded => histogram.resource_budget_exceeded += 1,
        FallbackReason.runtime_unavailable => histogram.runtime_unavailable += 1,
        FallbackReason.runtime_execute_failed => histogram.runtime_execute_failed += 1,
    }
}

fn glyphCount(request: Request) u32 {
    var total: u32 = 0;
    for (request.textRuns) |run| total += @intCast(run.glyphIds.len);
    return total;
}

fn deterministicTiming(glyph_count: u32, path_op_count: u32, draw_call_count: u32, sample_count: u32) TimingStats {
    return .{
        .setupNs = 10_000 + @as(u64, glyph_count) * 50 + @as(u64, path_op_count) * 30,
        .encodeNs = 5_000 + @as(u64, draw_call_count) * 120,
        .submitWaitNs = 2_000 + @as(u64, sample_count) * 500,
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

    const glyph_count = glyphCount(request);
    const path_op_count: u32 = @intCast(request.pathOps.len);
    const target_pixels = @as(u64, request.target.width) * @as(u64, request.target.height);
    const atlas_miss_count: u32 = if (glyph_count > policy.policy.atlasGlyphCapacity)
        glyph_count - policy.policy.atlasGlyphCapacity
    else
        0;
    const atlas_hit_count: u32 = glyph_count - atlas_miss_count;
    const text_run_count: u32 = @intCast(request.textRuns.len);
    const draw_call_count: u32 = text_run_count + (if (path_op_count <= 1) 1 else (path_op_count + 1) / 2);

    if (!containsStrings(policy.policy.allowedBlendModes, request.paintState.blendMode)) {
        addFallbackReason(&fallback_histogram, FallbackReason.unsupported_blend_mode);
        fallback_count += 1;
    }
    if (!containsStrings(policy.policy.allowedClipModes, request.paintState.clipState.mode)) {
        addFallbackReason(&fallback_histogram, FallbackReason.unsupported_clip_mode);
        fallback_count += 1;
    }
    if (!containsU32(policy.policy.allowedSampleCounts, request.target.sampleCount)) {
        addFallbackReason(&fallback_histogram, FallbackReason.required_capability_missing);
        fallback_count += 1;
    }
    if (path_op_count > policy.policy.maxPathOps) {
        addFallbackReason(&fallback_histogram, FallbackReason.path_complexity_exceeded);
        fallback_count += 1;
    }
    if (target_pixels > policy.policy.maxTargetPixels) {
        addFallbackReason(&fallback_histogram, FallbackReason.resource_budget_exceeded);
        fallback_count += 1;
    }

    const effective_draw_count: u32 = if (fallback_count == 0) draw_call_count else 0;
    const payload = ResultNoTrace{
        .schemaVersion = 1,
        .moduleId = MODULE_ID,
        .artifactKind = "result",
        .renderArtifact = .{ .artifactId = try std.fmt.allocPrint(allocator, "sdf://{s}", .{request_hash[0..16]}) },
        .renderStats = .{
            .drawCallCount = effective_draw_count,
            .atlasHitCount = atlas_hit_count,
            .atlasMissCount = atlas_miss_count,
            .passCount = if (fallback_count == 0) 1 else 0,
        },
        .timingStats = deterministicTiming(glyph_count, path_op_count, draw_call_count, request.target.sampleCount),
        .qualityStats = .{
            .fallbackCount = fallback_count,
            .fallbackReasonHistogram = fallback_histogram,
        },
    };
    const result_hash = try artifact.stableHashJsonAlloc(allocator, payload);
    return .{
        .schemaVersion = payload.schemaVersion,
        .moduleId = payload.moduleId,
        .artifactKind = payload.artifactKind,
        .renderArtifact = payload.renderArtifact,
        .renderStats = payload.renderStats,
        .timingStats = payload.timingStats,
        .qualityStats = payload.qualityStats,
        .traceLink = .{
            .moduleIdentity = MODULE_ID,
            .requestHash = request_hash,
            .policyHash = policy_hash,
            .resultHash = result_hash,
        },
    };
}
