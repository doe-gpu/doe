const std = @import("std");
const artifact = @import("../../../contracts/artifact.zig");

pub const MODULE_ID = "fawn_resource_scheduler";

pub const FallbackReason = error{
    cadence_policy_invalid,
    profile_policy_missing,
    determinism_guard_triggered,
    pool_limit_exceeded,
    resource_create_failed,
    runtime_unavailable,
};

pub const ResourceRequest = struct {
    type: []const u8,
    bytes: u64,
    usage: []const u8,
};

pub const WorkloadContext = struct {
    moduleId: []const u8,
    operationClass: []const u8,
};

pub const SchedulerPolicy = struct {
    poolLimitBytes: u64,
    cadenceMode: []const u8,
    evictionPolicyMode: []const u8,
};

pub const Profile = struct {
    vendor: []const u8,
    api: []const u8,
    deviceFamily: []const u8,
    driver: []const u8,
};

pub const Request = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    resourceRequest: []const ResourceRequest,
    workloadContext: WorkloadContext,
    schedulerPolicy: SchedulerPolicy,
    profile: Profile,
};

pub const PolicyBody = struct {
    allowedCadenceModes: []const []const u8,
    allowedModules: []const []const u8,
    maxPoolBytes: u64,
    maxResourcesPerRequest: u32,
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

pub const AllocationResult = struct {
    resourceId: []const u8,
    disposition: []const u8,
    bytesGranted: u64,
};

pub const PoolStats = struct {
    hitCount: u32,
    missCount: u32,
    evictionCount: u32,
    highWaterBytes: u64,
};

pub const SubmitStats = struct {
    submitCount: u32,
    cadenceModeUsed: []const u8,
};

pub const FallbackReasonHistogram = struct {
    cadence_policy_invalid: u32 = 0,
    profile_policy_missing: u32 = 0,
    determinism_guard_triggered: u32 = 0,
    pool_limit_exceeded: u32 = 0,
    resource_create_failed: u32 = 0,
};

pub const ResultNoTrace = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    allocationResult: []const AllocationResult,
    poolStats: PoolStats,
    submitStats: SubmitStats,
    fallbackStats: FallbackStatsJson,
};

pub const FallbackStatsJson = struct {
    fallbackCount: u32,
    fallbackReasonHistogram: FallbackReasonHistogram,
};

pub const Result = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    allocationResult: []const AllocationResult,
    poolStats: PoolStats,
    submitStats: SubmitStats,
    fallbackStats: FallbackStatsJson,
    traceLink: artifact.TraceLink,
};

pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Request) {
    return try std.json.parseFromSlice(Request, allocator, bytes, .{ .ignore_unknown_fields = false });
}

pub fn parsePolicy(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Policy) {
    return try std.json.parseFromSlice(Policy, allocator, bytes, .{ .ignore_unknown_fields = false });
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn ensureValidRequest(request: Request) !void {
    if (!std.mem.eql(u8, request.moduleId, MODULE_ID)) return error.InvalidModuleId;
    if (!std.mem.eql(u8, request.artifactKind, "request")) return error.InvalidArtifactKind;
}

fn ensureValidPolicy(policy: Policy) !void {
    if (!std.mem.eql(u8, policy.moduleId, MODULE_ID)) return error.InvalidModuleId;
    if (!std.mem.eql(u8, policy.artifactKind, "policy")) return error.InvalidArtifactKind;
}

fn addFallbackReason(histogram: *FallbackReasonHistogram, key: []const u8) void {
    if (std.mem.eql(u8, key, "cadence_policy_invalid")) {
        histogram.cadence_policy_invalid += 1;
    } else if (std.mem.eql(u8, key, "profile_policy_missing")) {
        histogram.profile_policy_missing += 1;
    } else if (std.mem.eql(u8, key, "determinism_guard_triggered")) {
        histogram.determinism_guard_triggered += 1;
    } else if (std.mem.eql(u8, key, "pool_limit_exceeded")) {
        histogram.pool_limit_exceeded += 1;
    } else if (std.mem.eql(u8, key, "resource_create_failed")) {
        histogram.resource_create_failed += 1;
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
    var eviction_count: u32 = 0;

    if (!contains(policy.policy.allowedCadenceModes, request.schedulerPolicy.cadenceMode)) {
        addFallbackReason(&fallback_histogram, "cadence_policy_invalid");
        fallback_count += 1;
    }
    if (!contains(policy.policy.allowedModules, request.workloadContext.moduleId)) {
        addFallbackReason(&fallback_histogram, "profile_policy_missing");
        fallback_count += 1;
    }
    if (request.resourceRequest.len > policy.policy.maxResourcesPerRequest) {
        addFallbackReason(&fallback_histogram, "determinism_guard_triggered");
        fallback_count += 1;
        eviction_count = @intCast(request.resourceRequest.len - policy.policy.maxResourcesPerRequest);
    }

    const effective_pool_limit = @min(request.schedulerPolicy.poolLimitBytes, policy.policy.maxPoolBytes);
    if (request.schedulerPolicy.poolLimitBytes > policy.policy.maxPoolBytes) {
        addFallbackReason(&fallback_histogram, "pool_limit_exceeded");
        fallback_count += 1;
    }

    var allocations = std.ArrayList(AllocationResult).empty;
    defer allocations.deinit(allocator);

    const total_requested_bytes = blk: {
        var total: u64 = 0;
        for (request.resourceRequest) |entry| total += entry.bytes;
        break :blk total;
    };
    var bytes_used: u64 = 0;
    var hit_count: u32 = 0;
    var miss_count: u32 = 0;

    for (request.resourceRequest, 0..) |entry, index| {
        var disposition: []const u8 = if (index % 2 == 0) "reused" else "allocated";
        if (std.mem.eql(u8, disposition, "reused")) {
            hit_count += 1;
        } else {
            miss_count += 1;
        }

        var bytes_granted = entry.bytes;
        if (bytes_used + bytes_granted > effective_pool_limit) {
            disposition = "fallback";
            bytes_granted = if (bytes_used >= effective_pool_limit) 0 else effective_pool_limit - bytes_used;
            addFallbackReason(&fallback_histogram, "pool_limit_exceeded");
            fallback_count += 1;
        }

        bytes_used += bytes_granted;
        const resource_id = try std.fmt.allocPrint(allocator, "res_{d}", .{index});
        try allocations.append(allocator, .{
            .resourceId = resource_id,
            .disposition = disposition,
            .bytesGranted = bytes_granted,
        });
    }

    const payload = ResultNoTrace{
        .schemaVersion = 1,
        .moduleId = MODULE_ID,
        .artifactKind = "result",
        .allocationResult = try allocations.toOwnedSlice(allocator),
        .poolStats = .{
            .hitCount = hit_count,
            .missCount = miss_count,
            .evictionCount = eviction_count,
            .highWaterBytes = @min(total_requested_bytes, effective_pool_limit),
        },
        .submitStats = .{
            .submitCount = @max(@as(u32, 1), @as(u32, @intCast(request.resourceRequest.len / 2))),
            .cadenceModeUsed = request.schedulerPolicy.cadenceMode,
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
        .allocationResult = payload.allocationResult,
        .poolStats = payload.poolStats,
        .submitStats = payload.submitStats,
        .fallbackStats = payload.fallbackStats,
        .traceLink = .{
            .moduleIdentity = MODULE_ID,
            .requestHash = request_hash,
            .policyHash = policy_hash,
            .resultHash = result_hash,
        },
    };
}
