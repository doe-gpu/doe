const std = @import("std");
const execution_contract = @import("../contracts/execution.zig");
const model_commands = @import("../contracts/command.zig");
const model_profile = @import("../contracts/model/model_profile.zig");
const model_transfer_types = @import("../contracts/model/model_compute_types.zig");
const backend_ids = @import("../contracts/backend.zig");
const runtime_configuration = @import("../contracts/runtime_configuration.zig");
const runtime_telemetry = @import("../contracts/runtime_telemetry.zig");
const evidence_observer = @import("../contracts/evidence_observer.zig");
const port_factory = @import("../backend/ports/factory.zig");
const wgpu_loader = @import("../core/abi/wgpu_loader.zig");
const semantic_trace = @import("../contracts/semantic.zig");
const execution_receipt = @import("execution_receipt.zig");
const app = @import("../app/mod.zig");
const prepared_contract = @import("../contracts/prepared_operation.zig");

const model = struct {
    pub const Command = model_commands.Command;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const KernelBinding = model_transfer_types.KernelBinding;
    pub const SemVer = model_profile.SemVer;
};

const NativeOperation = union(enum) {
    command: model.Command,
    buffer_write_bytes: struct {
        handle: u64,
        offset: u64,
        buffer_size: u64,
        data: []const u8,
    },
};

fn prepareNativeOperation(operation: NativeOperation, operation_id: u64) prepared_contract.PreparedOperation {
    return switch (operation) {
        .command => |command| app.prepareCommand(command, operation_id),
        .buffer_write_bytes => |write| .{ .transfer = app.prepareTransfer(.{
            .buffer_handle = write.handle,
            .offset_bytes = write.offset,
            .size_bytes = write.buffer_size,
            .data = write.data,
        }, operation_id) },
    };
}

fn executeBackendOperation(ports: port_factory.PortBundle, observer: ?evidence_observer.EvidenceObserver, prepared_operation: prepared_contract.PreparedOperation) !execution_contract.NativeExecutionResult {
    if (observer) |value| value.onOperationPrepared(prepared_operation);
    const report = app.executePrepared(ports, prepared_operation) catch |err| {
        if (observer) |value| value.onOperationCompleted(prepared_operation, .fail(@errorName(err)));
        return err;
    };
    if (observer) |value| value.onOperationCompleted(prepared_operation, report);
    return report.toNative();
}

fn elapsedSince(start: i128) u64 {
    const end = std.time.nanoTimestamp();
    return if (end > start) @intCast(end - start) else 0;
}

pub const BackendMode = enum {
    trace,
    native,
};

pub const DEFAULT_WEBGPU_FFI_QUEUE_WAIT_TIMEOUT_NS: u64 = wgpu_loader.QUEUE_WAIT_TIMEOUT_NS;

pub const ExecutionStatus = execution_contract.ExecutionStatus;
pub const ExecutionResult = execution_receipt.ExecutionResult;

pub const ExecutionContext = struct {
    mode: BackendMode,
    backend_lane: backend_ids.BackendLane,
    ports: ?port_factory.PortBundle,
    observer: ?evidence_observer.EvidenceObserver = null,
    next_operation_id: u64 = 1,

    pub fn initTrace(lane: backend_ids.BackendLane) ExecutionContext {
        return .{
            .mode = .trace,
            .backend_lane = lane,
            .ports = null,
        };
    }

    pub fn initNative(lane: backend_ids.BackendLane, ports: port_factory.PortBundle) ExecutionContext {
        return .{
            .mode = .native,
            .backend_lane = lane,
            .ports = ports,
        };
    }

    pub fn deinit(self: *ExecutionContext) void {
        self.ports = null;
        self.observer = null;
    }

    pub fn setEvidenceObserver(self: *ExecutionContext, observer: ?evidence_observer.EvidenceObserver) void {
        self.observer = observer;
    }

    pub fn telemetry(self: *ExecutionContext) ?runtime_telemetry.RuntimeTelemetry {
        return if (self.ports) |ports| ports.telemetry.snapshot() else null;
    }

    pub fn execute(self: *ExecutionContext, command: model.Command) !ExecutionResult {
        return try self.execute_with_semantic(command, .{});
    }

    pub fn execute_buffer_write_bytes_with_semantic(
        self: *ExecutionContext,
        handle: u64,
        offset: u64,
        buffer_size: u64,
        data: []const u8,
        semantic: semantic_trace.SemanticContext,
    ) !ExecutionResult {
        return self.executeOperation(.{
            .buffer_write_bytes = .{
                .handle = handle,
                .offset = offset,
                .buffer_size = buffer_size,
                .data = data,
            },
        }, semantic);
    }

    pub fn execute_with_semantic(
        self: *ExecutionContext,
        command: model.Command,
        semantic: semantic_trace.SemanticContext,
    ) !ExecutionResult {
        return self.executeOperation(.{ .command = command }, semantic);
    }

    fn executeOperation(
        self: *ExecutionContext,
        operation: NativeOperation,
        semantic: semantic_trace.SemanticContext,
    ) ExecutionResult {
        const mode_name = executionModeName(self.mode);
        const operation_id = self.next_operation_id;
        self.next_operation_id +%= 1;
        const prepared_operation = prepareNativeOperation(operation, operation_id);
        if (self.mode == .trace) {
            if (self.observer) |observer| {
                observer.onOperationPrepared(prepared_operation);
                observer.onOperationCompleted(prepared_operation, .{ .status = .skipped });
            }
            return execution_receipt.skipped(.{
                .backend = mode_name,
                .backend_lane = null,
                .semantic = semantic,
            });
        }

        const ports = self.ports orelse {
            return execution_receipt.missingBackend(.{
                .backend = mode_name,
                .backend_lane = backendLaneName(self.backend_lane),
                .semantic = semantic,
            });
        };
        const telemetry_snapshot = ports.telemetry.snapshot();
        const identity = execution_receipt.Identity{
            .backend = backend_id_name(telemetry_snapshot.backend_id),
            .backend_lane = backendLaneName(self.backend_lane),
            .semantic = semantic,
        };
        const command_start = std.time.nanoTimestamp();
        const native = executeBackendOperation(ports, self.observer, prepared_operation) catch |err| {
            const duration_ns = elapsedSince(command_start);
            const command_telemetry = ports.telemetry.snapshot();
            return execution_receipt.failure(
                identity,
                command_telemetry,
                duration_ns,
                @errorName(err),
            );
        };
        const duration_ns = elapsedSince(command_start);
        const command_telemetry = ports.telemetry.snapshot();
        return execution_receipt.success(
            identity,
            command_telemetry,
            duration_ns,
            native,
        );
    }

    pub fn configureUploadBehavior(
        self: *ExecutionContext,
        usage_mode: UploadBufferUsageMode,
        submit_every: u32,
    ) void {
        if (self.mode != .native) return;
        if (self.ports) |ports| ports.transfer.setUploadBehavior(usage_mode, submit_every);
    }

    pub fn configureQueueWaitMode(
        self: *ExecutionContext,
        wait_mode: QueueWaitMode,
    ) void {
        if (self.mode != .native) return;
        if (self.ports) |ports| ports.queue.setWaitMode(wait_mode);
    }

    pub fn configureWebgpuFfiQueueWaitTimeoutNs(
        self: *ExecutionContext,
        timeout_ns: u64,
    ) void {
        if (self.mode != .native) return;
        if (self.ports) |ports| ports.queue.setWaitTimeoutNs(timeout_ns);
    }

    pub fn configureQueueSyncMode(
        self: *ExecutionContext,
        sync_mode: QueueSyncMode,
    ) void {
        if (self.mode != .native) return;
        if (self.ports) |ports| ports.queue.setSyncMode(sync_mode);
    }

    pub fn configureGpuTimestampMode(
        self: *ExecutionContext,
        timestamp_mode: GpuTimestampMode,
    ) void {
        if (self.mode != .native) return;
        if (self.ports) |ports| ports.compute.setGpuTimestampMode(timestamp_mode);
    }

    pub fn flushQueue(self: *ExecutionContext) !u64 {
        if (self.mode != .native) return 0;
        if (self.ports) |ports| return try ports.queue.flush();
        return 0;
    }

    pub fn prewarmUploadPath(
        self: *ExecutionContext,
        max_upload_bytes: u64,
    ) !void {
        if (self.mode != .native) return;
        if (self.ports) |ports| try ports.transfer.prewarmUpload(max_upload_bytes);
    }

    pub fn prewarmKernelDispatch(
        self: *ExecutionContext,
        kernel: []const u8,
        entry_point: ?[]const u8,
        bindings: ?[]const model.KernelBinding,
        initialize_buffers_on_create: bool,
    ) !void {
        if (self.mode != .native) return;
        if (self.ports) |ports| {
            try ports.compute.prewarmKernel(
                kernel,
                entry_point,
                bindings,
                initialize_buffers_on_create,
            );
        }
    }

    pub fn captureBuffer(
        self: *ExecutionContext,
        allocator: std.mem.Allocator,
        handle: u64,
        offset: u64,
        size: u64,
    ) ![]u8 {
        if (self.mode != .native) return error.UnsupportedFeature;
        if (self.ports) |ports| return try ports.readback.captureBuffer(allocator, handle, offset, size);
        return error.UnsupportedFeature;
    }
};

pub const UploadBufferUsageMode = runtime_configuration.UploadBufferUsageMode;
pub const QueueWaitMode = runtime_configuration.QueueWaitMode;
pub const QueueSyncMode = runtime_configuration.QueueSyncMode;
pub const GpuTimestampMode = runtime_configuration.GpuTimestampMode;

pub fn parseUploadBufferUsage(raw: []const u8) ?UploadBufferUsageMode {
    if (std.ascii.eqlIgnoreCase(raw, "copy-dst-copy-src")) return .copy_dst_copy_src;
    if (std.ascii.eqlIgnoreCase(raw, "copy-dst")) return .copy_dst;
    return null;
}

pub fn parseQueueWaitMode(raw: []const u8) ?QueueWaitMode {
    if (std.ascii.eqlIgnoreCase(raw, "process-events")) return .process_events;
    if (std.ascii.eqlIgnoreCase(raw, "wait-any")) return .wait_any;
    return null;
}

pub fn queueWaitModeName(mode: QueueWaitMode) []const u8 {
    return switch (mode) {
        .process_events => "process-events",
        .wait_any => "wait-any",
    };
}

pub fn parseQueueSyncMode(raw: []const u8) ?QueueSyncMode {
    if (std.ascii.eqlIgnoreCase(raw, "per-command")) return .per_command;
    if (std.ascii.eqlIgnoreCase(raw, "deferred")) return .deferred;
    return null;
}

pub fn queueSyncModeName(mode: QueueSyncMode) []const u8 {
    return switch (mode) {
        .per_command => "per-command",
        .deferred => "deferred",
    };
}

pub fn parseGpuTimestampMode(raw: []const u8) ?GpuTimestampMode {
    if (std.ascii.eqlIgnoreCase(raw, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(raw, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(raw, "require")) return .require;
    return null;
}

pub fn parseBackend(raw: []const u8) ?BackendMode {
    if (std.ascii.eqlIgnoreCase(raw, "trace")) return .trace;
    if (std.ascii.eqlIgnoreCase(raw, "native")) return .native;
    if (std.ascii.eqlIgnoreCase(raw, "webgpu")) return .native;
    return null;
}

pub fn parseBackendLane(raw: []const u8) ?backend_ids.BackendLane {
    return backend_ids.parseLane(raw);
}

pub fn defaultBackendLane(profile: model.DeviceProfile) backend_ids.BackendLane {
    return switch (profile.api) {
        .metal => .metal_doe_app,
        .d3d12 => .d3d12_doe_app,
        else => .vulkan_doe_app,
    };
}

pub fn backendLaneName(lane: backend_ids.BackendLane) []const u8 {
    return backend_ids.laneName(lane);
}

pub fn backend_id_name(id: backend_ids.BackendId) []const u8 {
    return backend_ids.backend_id_name(id);
}

pub fn executionModeName(mode: BackendMode) []const u8 {
    return switch (mode) {
        .trace => "trace",
        .native => "webgpu-ffi",
    };
}

pub fn executionStatusName(status: ExecutionStatus) []const u8 {
    return execution_contract.statusName(status);
}

// --- Inline tests ---

const testing = std.testing;

test "executionModeName returns correct strings for all modes" {
    try testing.expectEqualStrings("trace", executionModeName(.trace));
    try testing.expectEqualStrings("webgpu-ffi", executionModeName(.native));
}

test "executionStatusName returns correct strings for all statuses" {
    try testing.expectEqualStrings("skipped", executionStatusName(.skipped));
    try testing.expectEqualStrings("ok", executionStatusName(.ok));
    try testing.expectEqualStrings("unsupported", executionStatusName(.unsupported));
    try testing.expectEqualStrings("error", executionStatusName(.@"error"));
}

test "parseBackend accepts valid modes and rejects unknown input" {
    try testing.expectEqual(BackendMode.trace, parseBackend("trace").?);
    try testing.expectEqual(BackendMode.native, parseBackend("native").?);
    try testing.expectEqual(BackendMode.native, parseBackend("webgpu").?);
    // case-insensitive
    try testing.expectEqual(BackendMode.trace, parseBackend("TRACE").?);
    try testing.expectEqual(BackendMode.native, parseBackend("Native").?);
    try testing.expectEqual(BackendMode.native, parseBackend("WebGPU").?);
    // unknown returns null
    try testing.expect(parseBackend("opengl") == null);
    try testing.expect(parseBackend("") == null);
}

test "parseUploadBufferUsage accepts valid modes and rejects unknown input" {
    try testing.expectEqual(UploadBufferUsageMode.copy_dst_copy_src, parseUploadBufferUsage("copy-dst-copy-src").?);
    try testing.expectEqual(UploadBufferUsageMode.copy_dst, parseUploadBufferUsage("copy-dst").?);
    // case-insensitive
    try testing.expectEqual(UploadBufferUsageMode.copy_dst, parseUploadBufferUsage("COPY-DST").?);
    // unknown
    try testing.expect(parseUploadBufferUsage("map-write") == null);
    try testing.expect(parseUploadBufferUsage("") == null);
}

test "parseQueueWaitMode accepts valid modes and rejects unknown input" {
    try testing.expectEqual(QueueWaitMode.process_events, parseQueueWaitMode("process-events").?);
    try testing.expectEqual(QueueWaitMode.wait_any, parseQueueWaitMode("wait-any").?);
    // case-insensitive
    try testing.expectEqual(QueueWaitMode.wait_any, parseQueueWaitMode("Wait-Any").?);
    // unknown
    try testing.expect(parseQueueWaitMode("spin") == null);
}

test "queueWaitModeName returns CLI spellings" {
    try testing.expectEqualStrings("process-events", queueWaitModeName(.process_events));
    try testing.expectEqualStrings("wait-any", queueWaitModeName(.wait_any));
}

test "parseQueueSyncMode accepts valid modes and rejects unknown input" {
    try testing.expectEqual(QueueSyncMode.per_command, parseQueueSyncMode("per-command").?);
    try testing.expectEqual(QueueSyncMode.deferred, parseQueueSyncMode("deferred").?);
    // case-insensitive
    try testing.expectEqual(QueueSyncMode.deferred, parseQueueSyncMode("DEFERRED").?);
    // unknown
    try testing.expect(parseQueueSyncMode("batch") == null);
}

test "queueSyncModeName returns CLI spellings" {
    try testing.expectEqualStrings("per-command", queueSyncModeName(.per_command));
    try testing.expectEqualStrings("deferred", queueSyncModeName(.deferred));
}

test "parseGpuTimestampMode accepts valid modes and rejects unknown input" {
    try testing.expectEqual(GpuTimestampMode.auto, parseGpuTimestampMode("auto").?);
    try testing.expectEqual(GpuTimestampMode.off, parseGpuTimestampMode("off").?);
    try testing.expectEqual(GpuTimestampMode.require, parseGpuTimestampMode("require").?);
    // case-insensitive
    try testing.expectEqual(GpuTimestampMode.require, parseGpuTimestampMode("REQUIRE").?);
    // unknown
    try testing.expect(parseGpuTimestampMode("maybe") == null);
}

test "parseBackendLane accepts snake_case and kebab-case variants" {
    // metal lanes
    try testing.expectEqual(backend_ids.BackendLane.metal_doe_app, parseBackendLane("metal_doe_app").?);
    try testing.expectEqual(backend_ids.BackendLane.metal_doe_app, parseBackendLane("metal-doe-app").?);
    try testing.expectEqual(backend_ids.BackendLane.metal_dawn_release, parseBackendLane("metal-dawn-release").?);
    try testing.expectEqual(backend_ids.BackendLane.metal_doe_comparable, parseBackendLane("metal_doe_comparable").?);
    try testing.expectEqual(backend_ids.BackendLane.metal_webkit_comparable, parseBackendLane("metal_webkit_comparable").?);
    try testing.expectEqual(backend_ids.BackendLane.metal_webkit_comparable, parseBackendLane("metal-webkit-comparable").?);
    // vulkan lanes
    try testing.expectEqual(backend_ids.BackendLane.vulkan_doe_app, parseBackendLane("vulkan-doe-app").?);
    try testing.expectEqual(backend_ids.BackendLane.vulkan_doe_compute_only_fence_diagnostic, parseBackendLane("vulkan-doe-compute-only-fence-diagnostic").?);
    try testing.expectEqual(backend_ids.BackendLane.vulkan_dawn_release, parseBackendLane("vulkan-dawn-release").?);
    // d3d12 lanes
    try testing.expectEqual(backend_ids.BackendLane.d3d12_doe_app, parseBackendLane("d3d12_doe_app").?);
    try testing.expectEqual(backend_ids.BackendLane.d3d12_dawn_release, parseBackendLane("d3d12-dawn-release").?);
    // unknown
    try testing.expect(parseBackendLane("opengl_doe_app") == null);
    try testing.expect(parseBackendLane("") == null);
}

test "backendLaneName round-trips with parseBackendLane for all lanes" {
    const lanes = [_]backend_ids.BackendLane{
        .metal_doe_app,
        .metal_doe_directional,
        .metal_doe_comparable,
        .metal_doe_release,
        .metal_dawn_release,
        .metal_webkit_release,
        .metal_webkit_comparable,
        .vulkan_doe_app,
        .vulkan_doe_comparable,
        .vulkan_doe_compute_only_diagnostic,
        .vulkan_doe_compute_only_fence_diagnostic,
        .vulkan_doe_release,
        .vulkan_dawn_release,
        .d3d12_doe_app,
        .d3d12_doe_directional,
        .d3d12_doe_comparable,
        .d3d12_doe_release,
        .d3d12_dawn_release,
    };
    for (lanes) |lane| {
        const name = backendLaneName(lane);
        const parsed = parseBackendLane(name);
        try testing.expect(parsed != null);
        try testing.expectEqual(lane, parsed.?);
    }
}

test "defaultBackendLane selects correct lane per API" {
    const base_ver = model.SemVer{ .major = 1, .minor = 0, .patch = 0 };
    const metal_profile = model.DeviceProfile{
        .vendor = "apple",
        .api = .metal,
        .driver_version = base_ver,
    };
    const vulkan_profile = model.DeviceProfile{
        .vendor = "nvidia",
        .api = .vulkan,
        .driver_version = base_ver,
    };
    const d3d12_profile = model.DeviceProfile{
        .vendor = "amd",
        .api = .d3d12,
        .driver_version = base_ver,
    };
    const webgpu_profile = model.DeviceProfile{
        .vendor = "generic",
        .api = .webgpu,
        .driver_version = base_ver,
    };
    try testing.expectEqual(backend_ids.BackendLane.metal_doe_app, defaultBackendLane(metal_profile));
    try testing.expectEqual(backend_ids.BackendLane.d3d12_doe_app, defaultBackendLane(d3d12_profile));
    try testing.expectEqual(backend_ids.BackendLane.vulkan_doe_app, defaultBackendLane(vulkan_profile));
    // webgpu falls to the else branch -> vulkan_doe_app
    try testing.expectEqual(backend_ids.BackendLane.vulkan_doe_app, defaultBackendLane(webgpu_profile));
}
