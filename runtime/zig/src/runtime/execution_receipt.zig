const execution_contract = @import("../contracts/execution.zig");
const semantic_trace = @import("../contracts/semantic.zig");
const backend_telemetry = @import("../backend/backend_telemetry.zig");

pub const ExecutionStatus = execution_contract.ExecutionStatus;

pub const ExecutionResult = struct {
    backend: []const u8,
    status: ExecutionStatus,
    status_code: []const u8,
    duration_ns: u64,
    setup_ns: u64,
    encode_ns: u64,
    submit_wait_ns: u64,
    dispatch_count: u32,
    submit_count: u32,
    gpu_timestamp_ns: u64,
    gpu_timestamp_attempted: bool,
    gpu_timestamp_valid: bool,
    backend_selection_reason: ?[]const u8,
    fallback_used: ?bool,
    selection_policy_hash: ?[]const u8,
    shader_artifact_manifest_path: ?[]const u8,
    shader_artifact_manifest_hash: ?[]const u8,
    host_plan_artifact_path: ?[]const u8,
    host_plan_artifact_hash: ?[]const u8,
    backend_lane: ?[]const u8,
    adapter_ordinal: ?u32,
    queue_family_index: ?u32,
    present_capable: ?bool,
    queue_family_policy: ?[]const u8 = null,
    queue_family_kind: ?[]const u8 = null,
    queue_family_queue_count: ?u32 = null,
    queue_family_timestamp_valid_bits: ?u32 = null,
    queue_family_supports_graphics: ?bool = null,
    semantic: semantic_trace.SemanticContext = .{},
};

pub const Identity = struct {
    backend: []const u8,
    backend_lane: ?[]const u8,
    semantic: semantic_trace.SemanticContext,
};

pub fn skipped(identity: Identity) ExecutionResult {
    return empty(identity, .skipped, "disabled");
}

pub fn missingBackend(identity: Identity) ExecutionResult {
    return empty(identity, .@"error", "missing-backend");
}

pub fn failure(
    identity: Identity,
    telemetry: backend_telemetry.BackendTelemetry,
    duration_ns: u64,
    status_code: []const u8,
) ExecutionResult {
    var result = empty(identity, .@"error", status_code);
    result.duration_ns = duration_ns;
    applyTelemetry(&result, telemetry);
    return result;
}

pub fn success(
    identity: Identity,
    telemetry: backend_telemetry.BackendTelemetry,
    duration_ns: u64,
    native: execution_contract.NativeExecutionResult,
) ExecutionResult {
    var result = empty(identity, execution_contract.fromNativeStatus(native.status), native.status_message);
    result.duration_ns = duration_ns;
    result.setup_ns = native.setup_ns;
    result.encode_ns = native.encode_ns;
    result.submit_wait_ns = native.submit_wait_ns;
    result.dispatch_count = native.dispatch_count;
    result.gpu_timestamp_ns = native.gpu_timestamp_ns;
    result.gpu_timestamp_attempted = native.gpu_timestamp_attempted;
    result.gpu_timestamp_valid = native.gpu_timestamp_valid;
    applyTelemetry(&result, telemetry);
    return result;
}

fn empty(identity: Identity, status: ExecutionStatus, status_code: []const u8) ExecutionResult {
    return .{
        .backend = identity.backend,
        .status = status,
        .status_code = status_code,
        .duration_ns = 0,
        .setup_ns = 0,
        .encode_ns = 0,
        .submit_wait_ns = 0,
        .dispatch_count = 0,
        .submit_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
        .backend_selection_reason = null,
        .fallback_used = null,
        .selection_policy_hash = null,
        .shader_artifact_manifest_path = null,
        .shader_artifact_manifest_hash = null,
        .host_plan_artifact_path = null,
        .host_plan_artifact_hash = null,
        .backend_lane = identity.backend_lane,
        .adapter_ordinal = null,
        .queue_family_index = null,
        .present_capable = null,
        .semantic = identity.semantic,
    };
}

fn applyTelemetry(result: *ExecutionResult, telemetry: backend_telemetry.BackendTelemetry) void {
    result.submit_count = telemetry.last_submit_count orelse 0;
    result.backend_selection_reason = telemetry.backend_selection_reason;
    result.fallback_used = telemetry.fallback_used;
    result.selection_policy_hash = telemetry.selection_policy_hash;
    result.shader_artifact_manifest_path = telemetry.shader_artifact_manifest_path;
    result.shader_artifact_manifest_hash = telemetry.shader_artifact_manifest_hash;
    result.host_plan_artifact_path = telemetry.host_plan_artifact_path;
    result.host_plan_artifact_hash = telemetry.host_plan_artifact_hash;
    result.adapter_ordinal = telemetry.adapter_ordinal;
    result.queue_family_index = telemetry.queue_family_index;
    result.present_capable = telemetry.present_capable;
    result.queue_family_policy = telemetry.queue_family_policy;
    result.queue_family_kind = telemetry.queue_family_kind;
    result.queue_family_queue_count = telemetry.queue_family_queue_count;
    result.queue_family_timestamp_valid_bits = telemetry.queue_family_timestamp_valid_bits;
    result.queue_family_supports_graphics = telemetry.queue_family_supports_graphics;
}

test "failure preserves backend telemetry and first failure code" {
    const std = @import("std");
    const telemetry = backend_telemetry.BackendTelemetry{
        .backend_id = .vulkan,
        .backend_selection_reason = "profile-api",
        .fallback_used = false,
        .selection_policy_hash = "policy-hash",
        .shader_artifact_manifest_path = "shader.json",
        .shader_artifact_manifest_hash = "shader-hash",
        .host_plan_artifact_path = "plan.json",
        .host_plan_artifact_hash = "plan-hash",
        .adapter_ordinal = 2,
        .queue_family_index = 3,
        .present_capable = true,
        .queue_family_policy = "prefer-graphics-compute",
        .queue_family_kind = "graphics-compute",
        .queue_family_queue_count = 4,
        .queue_family_timestamp_valid_bits = 64,
        .queue_family_supports_graphics = true,
        .last_submit_count = 5,
    };
    const result = failure(.{
        .backend = "doe_vulkan",
        .backend_lane = "physical",
        .semantic = .{},
    }, telemetry, 17, "InvalidState");

    try std.testing.expectEqual(ExecutionStatus.@"error", result.status);
    try std.testing.expectEqualStrings("InvalidState", result.status_code);
    try std.testing.expectEqual(@as(u64, 17), result.duration_ns);
    try std.testing.expectEqual(@as(u32, 5), result.submit_count);
    try std.testing.expectEqualStrings("shader-hash", result.shader_artifact_manifest_hash.?);
    try std.testing.expectEqual(@as(u32, 3), result.queue_family_index.?);
}

test "success maps native measurements without changing timing scope" {
    const std = @import("std");
    var telemetry = backend_telemetry.default_telemetry();
    telemetry.last_submit_count = 2;
    const result = success(.{
        .backend = "dawn_delegate",
        .backend_lane = "compatibility",
        .semantic = .{},
    }, telemetry, 19, .{
        .status = .ok,
        .status_message = "ok",
        .setup_ns = 3,
        .encode_ns = 5,
        .submit_wait_ns = 7,
        .dispatch_count = 11,
        .gpu_timestamp_ns = 13,
        .gpu_timestamp_attempted = true,
        .gpu_timestamp_valid = true,
    });

    try std.testing.expectEqual(ExecutionStatus.ok, result.status);
    try std.testing.expectEqual(@as(u64, 3), result.setup_ns);
    try std.testing.expectEqual(@as(u64, 5), result.encode_ns);
    try std.testing.expectEqual(@as(u64, 7), result.submit_wait_ns);
    try std.testing.expectEqual(@as(u32, 11), result.dispatch_count);
    try std.testing.expectEqual(@as(u32, 2), result.submit_count);
}
