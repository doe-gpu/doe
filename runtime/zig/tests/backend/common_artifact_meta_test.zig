const std = @import("std");
const artifact_meta = @import("../../src/contracts/artifact.zig");

test "native backends are claimable" {
    try std.testing.expect(artifact_meta.BackendKind.native_vulkan.is_claimable());
    try std.testing.expect(artifact_meta.BackendKind.native_metal.is_claimable());
    try std.testing.expect(artifact_meta.BackendKind.native_d3d12.is_claimable());
    try std.testing.expect(!artifact_meta.BackendKind.dawn_delegate.is_claimable());
}

test "cost model is not claimable" {
    try std.testing.expect(!artifact_meta.BackendKind.cost_model.is_claimable());
}

test "native backends are native" {
    try std.testing.expect(artifact_meta.BackendKind.native_vulkan.is_native());
    try std.testing.expect(artifact_meta.BackendKind.native_metal.is_native());
    try std.testing.expect(artifact_meta.BackendKind.native_d3d12.is_native());
    try std.testing.expect(!artifact_meta.BackendKind.dawn_delegate.is_native());
    try std.testing.expect(!artifact_meta.BackendKind.cost_model.is_native());
}

test "strict comparability is claimable" {
    try std.testing.expect(artifact_meta.ComparabilityClass.strict.is_claimable());
    try std.testing.expect(!artifact_meta.ComparabilityClass.directional.is_claimable());
    try std.testing.expect(!artifact_meta.ComparabilityClass.diagnostic.is_claimable());
}

test "classify cost model as diagnostic" {
    const meta = artifact_meta.classify(.cost_model, false, false);
    try std.testing.expectEqual(artifact_meta.TimingSource.cost_model, meta.timing_source);
    try std.testing.expectEqual(artifact_meta.ComparabilityClass.diagnostic, meta.comparability);
    try std.testing.expect(!meta.is_claimable());
}

test "classify native with gpu timestamp as strict" {
    const meta = artifact_meta.classify(.native_vulkan, true, true);
    try std.testing.expectEqual(artifact_meta.TimingSource.gpu_timestamp, meta.timing_source);
    try std.testing.expectEqual(artifact_meta.ComparabilityClass.strict, meta.comparability);
    try std.testing.expect(meta.is_claimable());
}

test "classify native without gpu timestamp as directional" {
    const meta = artifact_meta.classify(.native_vulkan, false, true);
    try std.testing.expectEqual(artifact_meta.TimingSource.cpu_submit_wait, meta.timing_source);
    try std.testing.expectEqual(artifact_meta.ComparabilityClass.directional, meta.comparability);
    try std.testing.expect(!meta.is_claimable());
}

test "classify dawn delegate with gpu timestamp as strict" {
    const meta = artifact_meta.classify(.dawn_delegate, true, true);
    try std.testing.expectEqual(artifact_meta.TimingSource.gpu_timestamp, meta.timing_source);
    try std.testing.expectEqual(artifact_meta.ComparabilityClass.strict, meta.comparability);
    try std.testing.expect(!meta.is_claimable());
}

test "classify dawn delegate without gpu timestamp as directional" {
    const meta = artifact_meta.classify(.dawn_delegate, false, false);
    try std.testing.expectEqual(artifact_meta.TimingSource.cpu_wall_clock, meta.timing_source);
    try std.testing.expectEqual(artifact_meta.ComparabilityClass.directional, meta.comparability);
    try std.testing.expect(!meta.is_claimable());
}

test "backend kind names are stable" {
    try std.testing.expectEqualStrings("native_vulkan", artifact_meta.BackendKind.native_vulkan.name());
    try std.testing.expectEqualStrings("dawn_delegate", artifact_meta.BackendKind.dawn_delegate.name());
    try std.testing.expectEqualStrings("cost_model", artifact_meta.BackendKind.cost_model.name());
}

test "timing source names are stable" {
    try std.testing.expectEqualStrings("gpu_timestamp", artifact_meta.TimingSource.gpu_timestamp.name());
    try std.testing.expectEqualStrings("cost_model", artifact_meta.TimingSource.cost_model.name());
}
