const std = @import("std");
const builtin = @import("builtin");
const model = @import("../../src/contracts/command.zig");
const profile = @import("../../src/contracts/model/model_profile.zig");
const gpu = @import("../../src/contracts/model/model_gpu_types.zig");
const webgpu = @import("../../src/compat/webgpu_ffi.zig");
const metal_mod = @import("../../src/backend/metal/mod.zig");
const provider_harness = @import("../support/provider_harness.zig");

const FlushWorker = struct {
    iface: *provider_harness.ProviderHarness,
    result_ns: u64 = 0,
    failed: bool = false,

    fn run(self: *FlushWorker) void {
        self.result_ns = self.iface.flush_queue() catch {
            self.failed = true;
            return;
        };
    }
};

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

test "metal upload timing charges staged host work to setup ns" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_timing");
    defer iface.deinit();

    iface.set_upload_behavior(.copy_dst, 1);
    const result = try iface.execute_command(model.Command{ .upload = .{
        .bytes = 1024 * 1024,
        .align_bytes = 4,
    } });
    try std.testing.expect(result.status == .ok);
    try std.testing.expect(result.setup_ns > 0);
    try std.testing.expectEqual(@as(u64, 0), result.encode_ns);
    try std.testing.expect(result.submit_wait_ns > 0);
}

test "metal upload flush cadence reports nonzero submit_wait_ns" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_barrier_timing");
    defer iface.deinit();

    // With submit_every = 1, every upload should flush inline.
    iface.set_upload_behavior(.copy_dst, 1);
    const upload_result = try iface.execute_command(model.Command{ .upload = .{
        .bytes = 256 * 1024,
        .align_bytes = 4,
    } });
    try std.testing.expect(upload_result.status == .ok);
    try std.testing.expect(upload_result.submit_wait_ns > 0);
}

test "metal deferred upload keeps per-command submit_wait_ns at zero until final flush" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_deferred_upload_timing");
    defer iface.deinit();

    iface.set_upload_behavior(.copy_dst, 1);
    iface.set_queue_sync_mode(.deferred);

    const upload_result = try iface.execute_command(model.Command{ .upload = .{
        .bytes = 256 * 1024,
        .align_bytes = 4,
    } });
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, upload_result.status);
    try std.testing.expectEqual(@as(u64, 0), upload_result.submit_wait_ns);
    const runtime = backend.get_runtime();
    try std.testing.expect(runtime.streaming_cmd_buf != null);
    try std.testing.expectEqual(@as(?*anyopaque, null), runtime.outstanding_cmd_buf);

    const flush_ns = try iface.flush_queue();
    try std.testing.expect(flush_ns > 0);
    try std.testing.expectEqual(@as(?*anyopaque, null), runtime.outstanding_cmd_buf);
    try std.testing.expectEqual(@as(usize, 0), runtime.streaming_uploads.items.len);
}

test "metal completion waits are isolated across concurrent runtimes" {
    if (builtin.os.tag != .macos) return;

    const backend_a = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface_a = harness(backend_a, "test_metal_wait_a");
    defer iface_a.deinit();

    const backend_b = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface_b = harness(backend_b, "test_metal_wait_b");
    defer iface_b.deinit();

    iface_a.set_upload_behavior(.copy_dst, 1);
    iface_b.set_upload_behavior(.copy_dst, 1);
    iface_a.set_queue_sync_mode(.deferred);
    iface_b.set_queue_sync_mode(.deferred);
    const command = model.Command{ .upload = .{
        .bytes = 2 * 1024 * 1024,
        .align_bytes = 4,
    } };
    _ = try iface_a.execute_command(command);
    _ = try iface_b.execute_command(command);

    var worker_a = FlushWorker{ .iface = &iface_a };
    var worker_b = FlushWorker{ .iface = &iface_b };
    const thread_a = try std.Thread.spawn(.{}, FlushWorker.run, .{&worker_a});
    const thread_b = try std.Thread.spawn(.{}, FlushWorker.run, .{&worker_b});
    thread_a.join();
    thread_b.join();

    try std.testing.expect(!worker_a.failed);
    try std.testing.expect(!worker_b.failed);
    try std.testing.expect(worker_a.result_ns > 0);
    try std.testing.expect(worker_b.result_ns > 0);
    try std.testing.expect(!backend_a.get_runtime().has_deferred_submissions);
    try std.testing.expect(!backend_b.get_runtime().has_deferred_submissions);
}

test "metal barrier flushes deferred upload work" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_barrier_flush");
    defer iface.deinit();

    iface.set_upload_behavior(.copy_dst, 1);
    iface.set_queue_sync_mode(.deferred);

    const upload_result = try iface.execute_command(model.Command{ .upload = .{
        .bytes = 64 * 1024,
        .align_bytes = 4,
    } });
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, upload_result.status);
    try std.testing.expectEqual(@as(u64, 0), upload_result.submit_wait_ns);

    const barrier_result = try iface.execute_command(model.Command{ .barrier = .{ .dependency_count = 1 } });
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, barrier_result.status);
    try std.testing.expect(barrier_result.submit_wait_ns > 0);
}

test "metal kernel_dispatch returns error when kernel file not found" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_timing_unsupported");
    defer iface.deinit();

    const result = try iface.execute_command(model.Command{ .kernel_dispatch = .{
        .kernel = "bench/kernels/shader_compile_pipeline_stress.wgsl",
        .x = 1,
        .y = 1,
        .z = 1,
    } });

    // Native Metal implements kernel_dispatch natively via MSL.
    // Tests run from runtime/zig/ so bench/kernels/ is not on the lookup path; expect .@"error".
    try std.testing.expect(result.status == .@"error");
}

test "metal copy contract path executes native buffer-to-texture copy" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_copy_contract");
    defer iface.deinit();

    const result = try iface.execute_command(model.Command{ .copy_buffer_to_texture = .{
        .direction = .buffer_to_texture,
        .src = .{ .handle = 51, .offset = 0, .bytes_per_row = 8, .rows_per_image = 2 },
        .dst = .{ .handle = 52, .kind = .texture, .width = 2, .height = 2, .depth_or_array_layers = 1, .format = gpu.WGPUTextureFormat_RGBA8Unorm, .usage = gpu.WGPUTextureUsage_CopyDst | gpu.WGPUTextureUsage_TextureBinding, .bytes_per_row = 8, .rows_per_image = 2 },
        .bytes = 16,
    } });
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, result.status);
    try std.testing.expect(result.encode_ns > 0 or result.submit_wait_ns > 0);
}

test "metal surface lifecycle executes full presentation protocol" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), null) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = harness(backend, "test_metal_surface_contract");
    defer iface.deinit();

    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, (try iface.execute_command(model.Command{ .surface_create = .{ .handle = 901 } })).status);
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, (try iface.execute_command(model.Command{ .surface_capabilities = .{ .handle = 901 } })).status);
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, (try iface.execute_command(model.Command{ .surface_configure = .{ .handle = 901, .width = 64, .height = 64, .format = gpu.WGPUTextureFormat_RGBA8Unorm } })).status);
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, (try iface.execute_command(model.Command{ .surface_acquire = .{ .handle = 901 } })).status);
    const present = try iface.execute_command(model.Command{ .surface_present = .{ .handle = 901 } });
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, present.status);
    try std.testing.expect(present.submit_wait_ns > 0);
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, (try iface.execute_command(model.Command{ .surface_unconfigure = .{ .handle = 901 } })).status);
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, (try iface.execute_command(model.Command{ .surface_release = .{ .handle = 901 } })).status);
}
