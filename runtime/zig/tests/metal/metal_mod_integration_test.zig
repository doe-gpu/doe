const std = @import("std");
const builtin = @import("builtin");
const model = @import("../../src/contracts/command.zig");
const profile = @import("../../src/contracts/model/model_profile.zig");
const capabilities = @import("../../src/contracts/capability.zig");
const metal_mod = @import("../../src/backend/metal/mod.zig");
const provider_harness = @import("../support/provider_harness.zig");

fn harness(backend: *metal_mod.ZigMetalBackend, reason: []const u8) provider_harness.ProviderHarness {
    return .init(
        backend.asPorts(reason, "test_policy_hash", false),
        backend,
        metal_mod.destroyContext,
    );
}

fn test_profile() profile.DeviceProfile {
    return .{
        .vendor = "apple",
        .api = .metal,
        .device_family = "m3",
        .driver_version = .{ .major = 1, .minor = 0, .patch = 0 },
    };
}

fn skip_if_runtime_unavailable(err: anyerror) bool {
    return switch (err) {
        error.LibraryOpenFailed,
        error.SymbolMissing,
        error.AdapterUnavailable,
        error.AdapterRequestFailed,
        error.AdapterRequestNoCallback,
        error.DeviceRequestFailed,
        error.DeviceRequestNoCallback,
        error.NativeInstanceUnavailable,
        error.NativeQueueUnavailable,
        error.UnsupportedFeature,
        => true,
        else => false,
    };
}

test "metal backend init fails fast on non-macos hosts" {
    if (builtin.os.tag == .macos) return;
    try std.testing.expectError(
        error.UnsupportedFeature,
        metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null),
    );
}

test "metal backend declares buffer_upload and barrier_sync capabilities" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_capabilities");
    defer iface.deinit();

    try std.testing.expect(backend.capability_set.supports(capabilities.Capability.buffer_upload));
    try std.testing.expect(backend.capability_set.supports(capabilities.Capability.barrier_sync));
    // Native Metal implements kernel_dispatch and render_draw natively.
    try std.testing.expect(backend.capability_set.supports(capabilities.Capability.kernel_dispatch));
    try std.testing.expect(backend.capability_set.supports(capabilities.Capability.render_draw));
}

test "metal backend upload executes natively and emits manifest telemetry" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_manifest");
    defer iface.deinit();

    const result = try iface.execute_command(model.Command{ .upload = .{
        .bytes = 1024 * 1024,
        .align_bytes = 4,
    } });

    try std.testing.expect(result.status == .ok);
    const runtime = backend.get_runtime();
    try std.testing.expect(!runtime.has_deferred_submissions);
    try std.testing.expectEqual(@as(?*anyopaque, null), runtime.streaming_cmd_buf);
    try std.testing.expectEqual(@as(usize, 0), runtime.streaming_uploads.items.len);
}

test "metal backend kernel_dispatch returns error when kernel file not found" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_unsupported");
    defer iface.deinit();

    const result = try iface.execute_command(model.Command{ .kernel_dispatch = .{
        .kernel = "bench/kernels/shader_compile_pipeline_stress.wgsl",
        .x = 1,
        .y = 1,
        .z = 1,
    } });

    // Native Metal implements kernel_dispatch; a missing .metal file returns .@"error", not .unsupported.
    // Tests run from runtime/zig/ so bench/kernels/ is not accessible here.
    try std.testing.expect(result.status == .@"error");
}

test "metal backend upload cadence and flush queue preserve execution result" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_upload_flush");
    defer iface.deinit();

    iface.set_upload_behavior(.copy_dst, 2);
    const first = try iface.execute_command(model.Command{
        .upload = .{
            .bytes = 256,
            .align_bytes = 4,
        },
    });
    try std.testing.expect(first.status == .ok);
    try std.testing.expectEqual(@as(u64, 0), first.submit_wait_ns);

    const flush_ns = try iface.flush_queue();
    try std.testing.expect(flush_ns > 0);

    const second = try iface.execute_command(model.Command{
        .upload = .{
            .bytes = 256,
            .align_bytes = 4,
        },
    });
    try std.testing.expect(second.status == .ok);
    try std.testing.expectEqual(@as(u64, 0), second.submit_wait_ns);
}
