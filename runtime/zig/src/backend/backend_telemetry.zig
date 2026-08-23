const runtime_telemetry = @import("../contracts/runtime_telemetry.zig");
const backend_contract = @import("../contracts/backend.zig");

pub const BackendTelemetry = runtime_telemetry.RuntimeTelemetry;

pub fn default_telemetry() BackendTelemetry {
    return runtime_telemetry.defaultTelemetry();
}

pub fn forSelection(
    backend_id: backend_contract.BackendId,
    reason: []const u8,
    fallback_used: bool,
    policy_hash: []const u8,
) BackendTelemetry {
    var telemetry = default_telemetry();
    telemetry.backend_id = backend_id;
    telemetry.backend_selection_reason = reason;
    telemetry.fallback_used = fallback_used;
    telemetry.selection_policy_hash = policy_hash;
    return telemetry;
}
