const builtin = @import("builtin");
const std = @import("std");
const model = @import("../../src/contracts/model/model.zig");
const webgpu = @import("../../src/compat/webgpu_ffi.zig");
const common_errors = @import("../../src/backend/common/errors.zig");
const command_info = @import("../../src/backend/common/command_info.zig");
const d3d12_mod = @import("../../src/backend/d3d12/mod.zig");

const STATUS_MESSAGE_RING_SLOTS: usize = 32;
const STATUS_MESSAGE_SLOT_BYTES: usize = 256;
threadlocal var status_message_storage: [STATUS_MESSAGE_RING_SLOTS][STATUS_MESSAGE_SLOT_BYTES]u8 = undefined;
threadlocal var status_message_storage_len: [STATUS_MESSAGE_RING_SLOTS]usize = [_]usize{0} ** STATUS_MESSAGE_RING_SLOTS;
threadlocal var status_message_slot_next: usize = 0;

fn test_profile() model.DeviceProfile {
    return .{
        .vendor = "amd",
        .api = .d3d12,
        .device_family = "gfx11",
        .driver_version = .{ .major = 24, .minor = 0, .patch = 0 },
    };
}

// NativeExecutionResult.status_message may borrow backend-owned storage. These test
// helpers tear the backend down before returning, so persist the message first.
fn persistStatusMessage(message: []const u8) []const u8 {
    if (message.len == 0) return "";

    const slot = status_message_slot_next % STATUS_MESSAGE_RING_SLOTS;
    status_message_slot_next +%= 1;
    const len = @min(message.len, STATUS_MESSAGE_SLOT_BYTES);
    @memcpy(status_message_storage[slot][0..len], message[0..len]);
    status_message_storage_len[slot] = len;
    return status_message_storage[slot][0..status_message_storage_len[slot]];
}

fn persistResult(result: webgpu.NativeExecutionResult) webgpu.NativeExecutionResult {
    var stable = result;
    stable.status_message = persistStatusMessage(result.status_message);
    return stable;
}

fn unsupportedResult(command: model.Command, status_message: []const u8, err: anyerror) webgpu.NativeExecutionResult {
    return persistResult(.{
        .status = common_errors.map_error_status(err),
        .status_message = status_message,
        .setup_ns = 0,
        .encode_ns = 0,
        .submit_wait_ns = 0,
        .dispatch_count = if (command_info.is_dispatch(command)) command_info.operation_count(command) else 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    });
}

pub fn run_contract_path(command: model.Command, queue_sync_mode: webgpu.QueueSyncMode) !webgpu.NativeExecutionResult {
    if (builtin.os.tag != .windows) {
        return unsupportedResult(command, "d3d12-native-tests-require-windows", error.UnsupportedFeature);
    }

    const backend = d3d12_mod.ZigD3D12Backend.init(std.testing.allocator, test_profile(), null) catch |err| {
        return unsupportedResult(command, common_errors.error_code(err), err);
    };
    var iface = d3d12_mod.ZigD3D12Backend.as_iface(backend, std.testing.allocator, "d3d12_contract_test", "d3d12_contract_test_policy") catch |err| {
        return unsupportedResult(command, common_errors.error_code(err), err);
    };
    defer iface.deinit();
    iface.set_queue_sync_mode(queue_sync_mode);
    return persistResult(try iface.execute_command(command));
}
