const std = @import("std");
const builtin = @import("builtin");
const model = @import("../../src/model.zig");
const capabilities = @import("../../src/backend/common/capabilities.zig");
const metal_mod = @import("../../src/backend/metal/mod.zig");

const TEST_KERNEL_ROOT: []const u8 = "../../bench/kernels";
const TEST_COMPUTE_BUFFER_HANDLE: u64 = 7001;
const TEST_COMPUTE_WORD_COUNT: usize = 1024;
const TEST_COMPUTE_WORD_COUNT_U32: u32 = 1024;
const TEST_COMPUTE_ITERATION_COUNT: u32 = 1_000_000;
const TEST_COMPUTE_BUFFER_BYTES: u64 = TEST_COMPUTE_WORD_COUNT * @sizeOf(u32);

fn test_profile() model.DeviceProfile {
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

fn make_test_compute_input() [TEST_COMPUTE_WORD_COUNT]u32 {
    var data: [TEST_COMPUTE_WORD_COUNT]u32 = undefined;
    for (&data, 0..) |*value, index| {
        value.* = @intCast(index);
    }
    return data;
}

fn expected_concurrent_execution_result(input: []const u32) u32 {
    var threadgroup_words: [TEST_COMPUTE_WORD_COUNT]u32 = undefined;
    @memcpy(threadgroup_words[0..input.len], input);

    var accum = input[0];
    var i: u32 = 0;
    while (i < TEST_COMPUTE_ITERATION_COUNT) : (i += 1) {
        const idx: usize = @intCast((i +% accum) % TEST_COMPUTE_WORD_COUNT_U32);
        accum = (accum ^ threadgroup_words[idx]) +% 123;
    }
    return accum;
}

fn read_u32_word(bytes: []const u8, index: usize) u32 {
    const start = index * @sizeOf(u32);
    return std.mem.readInt(u32, bytes[start..][0..@sizeOf(u32)], .little);
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
    var iface = try backend.as_iface(std.testing.allocator, "test_metal_capabilities", "test_policy_hash");
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
    var iface = try backend.as_iface(std.testing.allocator, "test_metal_manifest", "test_policy_hash");
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
    var iface = try backend.as_iface(std.testing.allocator, "test_metal_unsupported", "test_policy_hash");
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
    var iface = try backend.as_iface(std.testing.allocator, "test_metal_upload_flush", "test_policy_hash");
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

test "metal backend kernel_dispatch executes deterministic compute and capture_buffer validates output" {
    if (builtin.os.tag != .macos) return;

    const backend = metal_mod.ZigMetalBackend.init(std.testing.allocator, test_profile(), TEST_KERNEL_ROOT) catch |err| {
        if (skip_if_runtime_unavailable(err)) return;
        return err;
    };
    var iface = try backend.as_iface(std.testing.allocator, "test_metal_kernel_dispatch_e2e", "test_policy_hash");
    defer iface.deinit();

    var input = make_test_compute_input();
    const expected = expected_concurrent_execution_result(input[0..]);

    const write_result = try iface.execute_command(model.Command{ .buffer_write = .{
        .handle = TEST_COMPUTE_BUFFER_HANDLE,
        .buffer_size = TEST_COMPUTE_BUFFER_BYTES,
        .data = input[0..],
    } });
    try std.testing.expect(write_result.status == .ok);

    const bindings = [_]model.KernelBinding{.{
        .binding = 0,
        .resource_kind = .buffer,
        .resource_handle = TEST_COMPUTE_BUFFER_HANDLE,
        .buffer_size = TEST_COMPUTE_BUFFER_BYTES,
    }};
    const dispatch_result = try iface.execute_command(model.Command{ .kernel_dispatch = .{
        .kernel = "concurrent_execution_runsingle_u32",
        .x = 1,
        .y = 1,
        .z = 1,
        .bindings = bindings[0..],
    } });
    try std.testing.expect(dispatch_result.status == .ok);
    try std.testing.expectEqual(@as(u32, 1), dispatch_result.dispatch_count);
    try std.testing.expect(dispatch_result.submit_wait_ns > 0);

    const captured = try iface.capture_buffer(std.testing.allocator, TEST_COMPUTE_BUFFER_HANDLE, 0, TEST_COMPUTE_BUFFER_BYTES);
    defer std.testing.allocator.free(captured);

    try std.testing.expectEqual(expected, read_u32_word(captured, 0));
    try std.testing.expectEqual(input[1], read_u32_word(captured, 1));
    try std.testing.expectEqual(input[TEST_COMPUTE_WORD_COUNT / 2], read_u32_word(captured, TEST_COMPUTE_WORD_COUNT / 2));
    try std.testing.expectEqual(input[TEST_COMPUTE_WORD_COUNT - 1], read_u32_word(captured, TEST_COMPUTE_WORD_COUNT - 1));
}
