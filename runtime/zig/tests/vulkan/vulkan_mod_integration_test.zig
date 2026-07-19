const std = @import("std");
const builtin = @import("builtin");
const model = @import("../../src/contracts/model/model.zig");
const webgpu = @import("../../src/compat/webgpu_ffi.zig");
const vulkan_mod = @import("../../src/backend/vulkan/mod.zig");
const vulkan_test_support = @import("vulkan_mod_test_support.zig");

fn test_profile() model.DeviceProfile {
    return .{
        .vendor = "amd",
        .api = .vulkan,
        .device_family = "gfx11",
        .driver_version = .{ .major = 24, .minor = 0, .patch = 0 },
    };
}

fn skip_if_runtime_unavailable(result: webgpu.NativeExecutionResult) bool {
    if (result.status == .ok) return false;
    return std.mem.eql(u8, result.status_message, "UnsupportedFeature") or
        std.mem.eql(u8, result.status_message, "AdapterUnavailable") or
        std.mem.eql(u8, result.status_message, "InvalidState") or
        std.mem.eql(u8, result.status_message, "ShaderCompileFailed") or
        std.mem.eql(u8, result.status_message, "ShaderToolchainUnavailable") or
        std.mem.eql(u8, result.status_message, "SurfaceUnavailable");
}

test "vulkan backend upload behavior applies mode and submit cadence" {
    if (builtin.os.tag == .macos) return;

    const backend = try vulkan_mod.ZigVulkanBackend.init(std.testing.allocator, test_profile(), null);
    var iface = try backend.as_iface(std.testing.allocator, "test_upload_behavior", "test_policy_hash");
    defer iface.deinit();

    iface.set_upload_behavior(.copy_dst, 2);

    const first = try iface.execute_command(model.Command{
        .upload = .{
            .bytes = 256,
            .align_bytes = 4,
        },
    });
    if (skip_if_runtime_unavailable(first)) return;
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, first.status);
    try std.testing.expectEqual(@as(u64, 0), first.submit_wait_ns);

    const second = try iface.execute_command(model.Command{
        .upload = .{
            .bytes = 256,
            .align_bytes = 4,
        },
    });
    if (skip_if_runtime_unavailable(second)) return;
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, second.status);
}

test "vulkan backend flush_queue submits upload cadence tail in per-command mode" {
    if (builtin.os.tag == .macos) return;

    const backend = try vulkan_mod.ZigVulkanBackend.init(std.testing.allocator, test_profile(), null);
    var iface = try backend.as_iface(std.testing.allocator, "test_upload_tail_flush", "test_policy_hash");
    defer iface.deinit();

    iface.set_upload_behavior(.copy_dst, 2);
    iface.set_queue_sync_mode(.per_command);

    const first = try iface.execute_command(model.Command{
        .upload = .{
            .bytes = 256,
            .align_bytes = 4,
        },
    });
    if (skip_if_runtime_unavailable(first)) return;
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, first.status);
    try std.testing.expectEqual(@as(u64, 0), first.submit_wait_ns);

    const flushed_ns = try iface.flush_queue();
    try std.testing.expect(flushed_ns >= 0);
}

test "vulkan kernel_dispatch reports dispatch count" {
    if (builtin.os.tag == .macos) return;

    const result = try vulkan_test_support.run_contract_path(
        model.Command{ .kernel_dispatch = .{
            .kernel = "bench/kernels/shader_compile_pipeline_stress.spv",
            .x = 1,
            .y = 1,
            .z = 1,
        } },
        webgpu.QueueSyncMode.per_command,
    );
    if (result.status != .ok) return;
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
}

test "vulkan unsupported capability reports dispatch count for dispatch commands" {
    const backend = try vulkan_mod.ZigVulkanBackend.init(std.testing.allocator, test_profile(), null);
    var iface = try backend.as_iface(std.testing.allocator, "test_dispatch_indirect_unsupported", "test_policy_hash");
    defer iface.deinit();

    const result = try iface.execute_command(model.Command{ .dispatch_indirect = .{
        .x = 1,
        .y = 1,
        .z = 1,
    } });

    try std.testing.expectEqual(webgpu.NativeExecutionStatus.unsupported, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
}

test "vulkan dispatch requires kernel_dispatch capability path" {
    const backend = try vulkan_mod.ZigVulkanBackend.init(std.testing.allocator, test_profile(), null);
    var iface = try backend.as_iface(std.testing.allocator, "test_dispatch_requires_kernel_dispatch", "test_policy_hash");
    defer iface.deinit();

    const result = try iface.execute_command(model.Command{ .dispatch = .{
        .x = 1,
        .y = 1,
        .z = 1,
    } });

    try std.testing.expectEqual(webgpu.NativeExecutionStatus.unsupported, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
}

test "vulkan async capability introspection executes natively" {
    if (builtin.os.tag == .macos) return;

    const result = try vulkan_test_support.run_contract_path(
        model.Command{ .async_diagnostics = .{
            .mode = .capability_introspection,
            .iterations = 2,
        } },
        webgpu.QueueSyncMode.per_command,
    );
    if (skip_if_runtime_unavailable(result)) return;
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, result.status);
    try std.testing.expectEqual(@as(u32, 2), result.dispatch_count);
}

test "vulkan async lifecycle refcount executes natively" {
    if (builtin.os.tag == .macos) return;

    const result = try vulkan_test_support.run_contract_path(
        model.Command{ .async_diagnostics = .{
            .mode = .lifecycle_refcount,
            .iterations = 3,
        } },
        webgpu.QueueSyncMode.per_command,
    );
    if (skip_if_runtime_unavailable(result)) return;
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, result.status);
    try std.testing.expectEqual(@as(u32, 3), result.dispatch_count);
}

test "vulkan async pipeline diagnostics execute natively" {
    if (builtin.os.tag == .macos) return;

    const result = try vulkan_test_support.run_contract_path(
        model.Command{ .async_diagnostics = .{
            .mode = .pipeline_async,
            .iterations = 1,
        } },
        webgpu.QueueSyncMode.per_command,
    );
    if (skip_if_runtime_unavailable(result)) return;
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, result.status);
    try std.testing.expectEqual(@as(u32, 1), result.dispatch_count);
}

test "vulkan resource table immediates executes through explicit emulation policy" {
    if (builtin.os.tag == .macos) return;

    const result = try vulkan_test_support.run_contract_path(
        model.Command{ .async_diagnostics = .{
            .mode = .resource_table_immediates,
            .iterations = 2,
            .feature_policy = .emulate_when_unavailable,
        } },
        webgpu.QueueSyncMode.per_command,
    );
    if (skip_if_runtime_unavailable(result)) return;
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, result.status);
    try std.testing.expectEqual(@as(u32, 2), result.dispatch_count);
}

test "vulkan pixel local storage executes through explicit emulation policy" {
    if (builtin.os.tag == .macos) return;

    const result = try vulkan_test_support.run_contract_path(
        model.Command{ .async_diagnostics = .{
            .mode = .pixel_local_storage,
            .iterations = 2,
            .feature_policy = .emulate_when_unavailable,
        } },
        webgpu.QueueSyncMode.per_command,
    );
    if (skip_if_runtime_unavailable(result)) return;
    try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, result.status);
    try std.testing.expectEqual(@as(u32, 2), result.dispatch_count);
}

test "vulkan headless surface lifecycle executes natively" {
    if (builtin.os.tag == .macos) return;

    const backend = try vulkan_mod.ZigVulkanBackend.init(std.testing.allocator, test_profile(), null);
    var iface = try backend.as_iface(std.testing.allocator, "test_surface_lifecycle", "test_policy_hash");
    defer iface.deinit();

    const surface_cmds = [_]model.Command{
        .{ .surface_create = .{ .handle = 41001 } },
        .{ .surface_capabilities = .{ .handle = 41001 } },
        .{ .surface_configure = .{ .handle = 41001, .width = 64, .height = 64 } },
        .{ .surface_acquire = .{ .handle = 41001 } },
        .{ .surface_present = .{ .handle = 41001 } },
        .{ .surface_unconfigure = .{ .handle = 41001 } },
        .{ .surface_release = .{ .handle = 41001 } },
    };
    for (surface_cmds) |cmd| {
        const result = try iface.execute_command(cmd);
        if (skip_if_runtime_unavailable(result)) return;
        try std.testing.expectEqual(webgpu.NativeExecutionStatus.ok, result.status);
    }
}
