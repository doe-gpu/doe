const std = @import("std");
const artifact = @import("../../../contracts/artifact.zig");

pub const MODULE_ID = "fawn_compute_services";

pub const FallbackReason = error{
    service_id_unknown,
    kernel_id_unknown,
    input_contract_invalid,
    dispatch_contract_invalid,
    runtime_unavailable,
    runtime_execute_failed,
};

pub const Input = struct {
    kind: []const u8,
    bytes: u64,
};

pub const Dispatch = struct {
    x: u32,
    y: u32,
    z: u32,
};

pub const RequestPolicy = struct {
    safetyClass: []const u8,
    verificationMode: []const u8,
};

pub const Request = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    serviceId: []const u8,
    kernelId: []const u8,
    inputs: []const Input,
    dispatch: Dispatch,
    policy: RequestPolicy,
};

pub const ServicePolicy = struct {
    sdf_atlas_upload: []const []const u8,
    path_mask_reduce: []const []const u8,
};

pub const PolicyBody = struct {
    services: ServicePolicy,
    maxDispatchesPerRequest: u32,
    maxInputBytes: u64,
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

pub const ServiceResult = struct {
    status: []const u8,
};

pub const ExecutionStats = struct {
    dispatchCount: u64,
    bytesMoved: u64,
};

pub const TimingStats = struct {
    setupNs: u64,
    encodeNs: u64,
    submitNs: u64,
    dispatchNs: u64,
};

pub const FailureDetails = struct {
    code: []const u8,
};

pub const ResultNoTrace = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    serviceResult: ServiceResult,
    executionStats: ExecutionStats,
    timingStats: TimingStats,
    failureDetails: FailureDetails,
};

pub const Result = struct {
    schemaVersion: u32,
    moduleId: []const u8,
    artifactKind: []const u8,
    serviceResult: ServiceResult,
    executionStats: ExecutionStats,
    timingStats: TimingStats,
    failureDetails: FailureDetails,
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
    if (request.dispatch.x == 0 or request.dispatch.y == 0 or request.dispatch.z == 0) {
        return error.InvalidDispatch;
    }
}

fn ensureValidPolicy(policy: Policy) !void {
    if (!std.mem.eql(u8, policy.moduleId, MODULE_ID)) return error.InvalidModuleId;
    if (!std.mem.eql(u8, policy.artifactKind, "policy")) return error.InvalidArtifactKind;
}

fn totalInputBytes(request: Request) u64 {
    var total: u64 = 0;
    for (request.inputs) |entry| total += entry.bytes;
    return total;
}

fn dispatchCount(request: Request) u64 {
    return @as(u64, request.dispatch.x) * @as(u64, request.dispatch.y) * @as(u64, request.dispatch.z);
}

fn serviceContains(candidates: []const []const u8, kernel_id: []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, candidate, kernel_id)) return true;
    }
    return false;
}

fn ensureSupportedKernel(request: Request, policy: Policy) !void {
    if (std.mem.eql(u8, request.serviceId, "sdf_atlas_upload")) {
        if (!serviceContains(policy.policy.services.sdf_atlas_upload, request.kernelId)) {
            return FallbackReason.kernel_id_unknown;
        }
        return;
    }
    if (std.mem.eql(u8, request.serviceId, "path_mask_reduce")) {
        if (!serviceContains(policy.policy.services.path_mask_reduce, request.kernelId)) {
            return FallbackReason.kernel_id_unknown;
        }
        return;
    }
    return FallbackReason.service_id_unknown;
}

fn deterministicTiming(request: Request) TimingStats {
    const dispatch_total = dispatchCount(request);
    return .{
        .setupNs = 6_000 + @as(u64, @intCast(request.inputs.len)) * 300,
        .encodeNs = 5_000 + dispatch_total * 2,
        .submitNs = 3_000 + dispatch_total,
        .dispatchNs = 4_000 + dispatch_total * 3,
    };
}

fn failureCodeFor(reason: ?FallbackReason) []const u8 {
    if (reason) |actual| {
        return @errorName(actual);
    }
    return "none";
}

pub fn execute(allocator: std.mem.Allocator, request: Request, policy: Policy) !Result {
    try ensureValidRequest(request);
    try ensureValidPolicy(policy);

    const request_hash = try artifact.stableHashJsonAlloc(allocator, request);
    errdefer allocator.free(request_hash);
    const policy_hash = try artifact.stableHashJsonAlloc(allocator, policy);
    errdefer allocator.free(policy_hash);

    const bytes_moved = totalInputBytes(request);
    const dispatch_total = dispatchCount(request);

    var fallback_reason: ?FallbackReason = null;
    if (bytes_moved > policy.policy.maxInputBytes) {
        fallback_reason = FallbackReason.input_contract_invalid;
    } else if (dispatch_total > policy.policy.maxDispatchesPerRequest) {
        fallback_reason = FallbackReason.dispatch_contract_invalid;
    }

    if (fallback_reason == null) {
        ensureSupportedKernel(request, policy) catch |err| {
            fallback_reason = err;
        };
    }

    const status = if (fallback_reason == null) "ok" else if (fallback_reason.? == FallbackReason.input_contract_invalid or fallback_reason.? == FallbackReason.dispatch_contract_invalid) "fallback" else "error";
    const payload = ResultNoTrace{
        .schemaVersion = 1,
        .moduleId = MODULE_ID,
        .artifactKind = "result",
        .serviceResult = .{ .status = status },
        .executionStats = .{
            .dispatchCount = dispatch_total,
            .bytesMoved = bytes_moved,
        },
        .timingStats = deterministicTiming(request),
        .failureDetails = .{ .code = failureCodeFor(fallback_reason) },
    };
    const result_hash = try artifact.stableHashJsonAlloc(allocator, payload);
    return .{
        .schemaVersion = payload.schemaVersion,
        .moduleId = payload.moduleId,
        .artifactKind = payload.artifactKind,
        .serviceResult = payload.serviceResult,
        .executionStats = payload.executionStats,
        .timingStats = payload.timingStats,
        .failureDetails = payload.failureDetails,
        .traceLink = .{
            .moduleIdentity = MODULE_ID,
            .requestHash = request_hash,
            .policyHash = policy_hash,
            .resultHash = result_hash,
        },
    };
}
