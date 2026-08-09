const std = @import("std");
const model_commands = @import("../contracts/command.zig");
const model_transfer_types = @import("../contracts/model/model_compute_types.zig");
const compute_contract = @import("../contracts/compute.zig");
const runtime_types = @import("runtime_types.zig");
const backend_ids = @import("../contracts/backend.zig");
const backend_telemetry = @import("backend_telemetry.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const KernelBinding = model_transfer_types.KernelBinding;
};

pub const BackendVTable = struct {
    deinit: *const fn (ctx: *anyopaque) void,
    execute_command: *const fn (ctx: *anyopaque, command: model.Command) anyerror!runtime_types.NativeExecutionResult,
    execute_dispatch: *const fn (context: compute_contract.ComputeContext, request: compute_contract.DispatchRequest) anyerror!compute_contract.DispatchReport,
    execute_buffer_write_bytes: *const fn (ctx: *anyopaque, handle: u64, offset: u64, buffer_size: u64, data: []const u8) anyerror!runtime_types.NativeExecutionResult,
    set_upload_behavior: *const fn (ctx: *anyopaque, mode: runtime_types.UploadBufferUsageMode, submit_every: u32) void,
    set_queue_wait_mode: *const fn (ctx: *anyopaque, mode: runtime_types.QueueWaitMode) void,
    set_webgpu_ffi_queue_wait_timeout_ns: *const fn (ctx: *anyopaque, timeout_ns: u64) void,
    set_queue_sync_mode: *const fn (ctx: *anyopaque, mode: runtime_types.QueueSyncMode) void,
    set_gpu_timestamp_mode: *const fn (ctx: *anyopaque, mode: runtime_types.GpuTimestampMode) void,
    flush_queue: *const fn (ctx: *anyopaque) anyerror!u64,
    prewarm_upload_path: *const fn (ctx: *anyopaque, max_upload_bytes: u64) anyerror!void,
    prewarm_kernel_dispatch: *const fn (
        ctx: *anyopaque,
        kernel: []const u8,
        entry_point: ?[]const u8,
        bindings: ?[]const model.KernelBinding,
        initialize_buffers_on_create: bool,
    ) anyerror!void,
    capture_buffer: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8,
};

pub const BackendIface = struct {
    id: backend_ids.BackendId,
    context: *anyopaque,
    vtable: *const BackendVTable,
    telemetry: backend_telemetry.BackendTelemetry,

    pub fn deinit(self: *BackendIface) void {
        self.vtable.deinit(self.context);
    }

    pub fn execute_command(self: *BackendIface, command: model.Command) !runtime_types.NativeExecutionResult {
        return switch (command) {
            .kernel_dispatch => |dispatch| (try self.execute_dispatch(
                compute_contract.DispatchRequest.fromCommand(dispatch),
            )).execution,
            else => try self.vtable.execute_command(self.context, command),
        };
    }

    pub fn execute_dispatch(self: *BackendIface, request: compute_contract.DispatchRequest) !compute_contract.DispatchReport {
        return try self.vtable.execute_dispatch(.{
            .backend = self.id,
            .state = self.context,
        }, request);
    }

    pub fn execute_buffer_write_bytes(self: *BackendIface, handle: u64, offset: u64, buffer_size: u64, data: []const u8) !runtime_types.NativeExecutionResult {
        return try self.vtable.execute_buffer_write_bytes(self.context, handle, offset, buffer_size, data);
    }

    pub fn set_upload_behavior(self: *BackendIface, mode: runtime_types.UploadBufferUsageMode, submit_every: u32) void {
        self.vtable.set_upload_behavior(self.context, mode, submit_every);
    }

    pub fn set_queue_wait_mode(self: *BackendIface, mode: runtime_types.QueueWaitMode) void {
        self.vtable.set_queue_wait_mode(self.context, mode);
    }

    pub fn set_webgpu_ffi_queue_wait_timeout_ns(self: *BackendIface, timeout_ns: u64) void {
        self.vtable.set_webgpu_ffi_queue_wait_timeout_ns(self.context, timeout_ns);
    }

    pub fn set_queue_sync_mode(self: *BackendIface, mode: runtime_types.QueueSyncMode) void {
        self.vtable.set_queue_sync_mode(self.context, mode);
    }

    pub fn set_gpu_timestamp_mode(self: *BackendIface, mode: runtime_types.GpuTimestampMode) void {
        self.vtable.set_gpu_timestamp_mode(self.context, mode);
    }

    pub fn flush_queue(self: *BackendIface) !u64 {
        return try self.vtable.flush_queue(self.context);
    }

    pub fn prewarm_upload_path(self: *BackendIface, max_upload_bytes: u64) !void {
        try self.vtable.prewarm_upload_path(self.context, max_upload_bytes);
    }

    pub fn prewarm_kernel_dispatch(
        self: *BackendIface,
        kernel: []const u8,
        entry_point: ?[]const u8,
        bindings: ?[]const model.KernelBinding,
        initialize_buffers_on_create: bool,
    ) !void {
        try self.vtable.prewarm_kernel_dispatch(
            self.context,
            kernel,
            entry_point,
            bindings,
            initialize_buffers_on_create,
        );
    }

    pub fn capture_buffer(self: *BackendIface, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) ![]u8 {
        return try self.vtable.capture_buffer(self.context, allocator, handle, offset, size);
    }
};

test "dedicated dispatch seam preserves characterized legacy command outcome" {
    const Mock = struct {
        dispatch_calls: u32 = 0,

        fn cast(ctx: *anyopaque) *@This() {
            return @as(*@This(), @ptrCast(@alignCast(ctx)));
        }

        fn deinit(_: *anyopaque) void {}

        fn executeCommand(ctx: *anyopaque, command: model.Command) anyerror!runtime_types.NativeExecutionResult {
            const self = cast(ctx);
            const dispatch = switch (command) {
                .kernel_dispatch => |value| value,
                else => return error.InvalidArgument,
            };
            self.dispatch_calls += 1;
            return .{
                .status = .ok,
                .status_message = dispatch.kernel,
                .setup_ns = 2,
                .encode_ns = 3,
                .submit_wait_ns = 5,
                .dispatch_count = dispatch.repeat,
                .gpu_timestamp_ns = 7,
                .gpu_timestamp_attempted = true,
                .gpu_timestamp_valid = true,
            };
        }

        fn executeDispatch(context: compute_contract.ComputeContext, request: compute_contract.DispatchRequest) anyerror!compute_contract.DispatchReport {
            return .{ .execution = try executeCommand(context.state, .{ .kernel_dispatch = request.toCommand() }) };
        }

        fn executeBufferWriteBytes(_: *anyopaque, _: u64, _: u64, _: u64, _: []const u8) anyerror!runtime_types.NativeExecutionResult {
            return error.Unsupported;
        }

        fn setUploadBehavior(_: *anyopaque, _: runtime_types.UploadBufferUsageMode, _: u32) void {}
        fn setQueueWaitMode(_: *anyopaque, _: runtime_types.QueueWaitMode) void {}
        fn setTimeout(_: *anyopaque, _: u64) void {}
        fn setQueueSyncMode(_: *anyopaque, _: runtime_types.QueueSyncMode) void {}
        fn setGpuTimestampMode(_: *anyopaque, _: runtime_types.GpuTimestampMode) void {}
        fn flushQueue(_: *anyopaque) anyerror!u64 {
            return 0;
        }
        fn prewarmUploadPath(_: *anyopaque, _: u64) anyerror!void {}
        fn prewarmKernelDispatch(_: *anyopaque, _: []const u8, _: ?[]const u8, _: ?[]const model.KernelBinding, _: bool) anyerror!void {}
        fn captureBuffer(_: *anyopaque, allocator: std.mem.Allocator, _: u64, _: u64, _: u64) anyerror![]u8 {
            return try allocator.alloc(u8, 0);
        }
    };

    const vtable = BackendVTable{
        .deinit = Mock.deinit,
        .execute_command = Mock.executeCommand,
        .execute_dispatch = Mock.executeDispatch,
        .execute_buffer_write_bytes = Mock.executeBufferWriteBytes,
        .set_upload_behavior = Mock.setUploadBehavior,
        .set_queue_wait_mode = Mock.setQueueWaitMode,
        .set_webgpu_ffi_queue_wait_timeout_ns = Mock.setTimeout,
        .set_queue_sync_mode = Mock.setQueueSyncMode,
        .set_gpu_timestamp_mode = Mock.setGpuTimestampMode,
        .flush_queue = Mock.flushQueue,
        .prewarm_upload_path = Mock.prewarmUploadPath,
        .prewarm_kernel_dispatch = Mock.prewarmKernelDispatch,
        .capture_buffer = Mock.captureBuffer,
    };
    var state = Mock{};
    var iface = BackendIface{
        .id = .doe_vulkan,
        .context = &state,
        .vtable = &vtable,
        .telemetry = .{
            .backend_id = .doe_vulkan,
            .backend_selection_reason = "test",
            .fallback_used = false,
            .selection_policy_hash = "test",
            .shader_artifact_manifest_path = null,
            .shader_artifact_manifest_hash = null,
            .host_plan_artifact_path = null,
            .host_plan_artifact_hash = null,
            .adapter_ordinal = null,
            .queue_family_index = null,
            .present_capable = null,
        },
    };
    const command = model.Command{ .kernel_dispatch = .{
        .kernel = "parity.wgsl",
        .x = 2,
        .y = 3,
        .z = 5,
        .repeat = 7,
    } };
    const characterized_legacy = try vtable.execute_command(iface.context, command);
    const promoted = try iface.execute_command(command);

    try std.testing.expectEqual(characterized_legacy.status, promoted.status);
    try std.testing.expectEqualStrings(characterized_legacy.status_message, promoted.status_message);
    try std.testing.expectEqual(characterized_legacy.setup_ns, promoted.setup_ns);
    try std.testing.expectEqual(characterized_legacy.encode_ns, promoted.encode_ns);
    try std.testing.expectEqual(characterized_legacy.submit_wait_ns, promoted.submit_wait_ns);
    try std.testing.expectEqual(characterized_legacy.dispatch_count, promoted.dispatch_count);
    try std.testing.expectEqual(characterized_legacy.gpu_timestamp_ns, promoted.gpu_timestamp_ns);
    try std.testing.expectEqual(characterized_legacy.gpu_timestamp_attempted, promoted.gpu_timestamp_attempted);
    try std.testing.expectEqual(characterized_legacy.gpu_timestamp_valid, promoted.gpu_timestamp_valid);
    try std.testing.expectEqual(@as(u32, 2), state.dispatch_calls);
}
