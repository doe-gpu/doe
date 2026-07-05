const std = @import("std");
const backend_telemetry = @import("../../src/backend/backend_telemetry.zig");

test "default backend telemetry is deterministic" {
    const telemetry = backend_telemetry.default_telemetry();
    try std.testing.expectEqualStrings("legacy_native_default", telemetry.backend_selection_reason);
    try std.testing.expectEqualStrings("backend-runtime-policy-v7", telemetry.selection_policy_hash);
}
