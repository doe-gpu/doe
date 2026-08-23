const std = @import("std");
const builtin = @import("builtin");
const model_commands = @import("../../contracts/command.zig");
const model_profile = @import("../../contracts/model/model_profile.zig");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const compute_contract = @import("../../contracts/compute.zig");
const prepared = @import("../../contracts/prepared_operation.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const model_texture_types = @import("../../contracts/model/model_texture_types.zig");
const model_async_types = @import("../../contracts/model/model_async_types.zig");
const webgpu = @import("../../contracts/runtime_types.zig");
const runtime_telemetry = @import("../../contracts/runtime_telemetry.zig");
const backend_telemetry = @import("../backend_telemetry.zig");
const port_factory = @import("../ports/factory.zig");
const provider_adapter = @import("../ports/provider_adapter.zig");
const common_errors = @import("../../contracts/execution.zig");
const common_timing = @import("../common/timing.zig");
const command_info = @import("../../contracts/command.zig");
const command_requirements = @import("../../contracts/command.zig");
const capabilities = @import("../../contracts/capability.zig");
const artifact_meta = @import("../../contracts/artifact.zig");
const artifact_policy = @import("../common/artifact_policy.zig");
const hash_utils = @import("../../contracts/artifact.zig");
const artifact_emit = @import("artifact_emit.zig");
const native_runtime = @import("d3d12_native_runtime.zig");

const MANIFEST_PATH_CAPACITY: usize = 256;

// Uploads accumulate and flush lazily: flush_pending_uploads_if_required fires
// once before the first non-upload command that needs to see the written data.
// This matches Dawn's batched-upload behavior and eliminates per-upload fence overhead.
const UPLOAD_BATCH_LAZY: u32 = std.math.maxInt(u32);
const HASH_HEX_SIZE: usize = hash_utils.SHA256_HEX_SIZE;
const MANIFEST_MODULE_CAPACITY: usize = 64;

const model = struct {
    pub const AsyncDiagnosticsCommand = model_async_types.AsyncDiagnosticsCommand;
    pub const Command = model_commands.Command;
    pub const CopyCommand = model_resource_types.CopyCommand;
    pub const DeviceProfile = model_profile.DeviceProfile;
    pub const DispatchCommand = model_compute_types.DispatchCommand;
    pub const DispatchIndirectCommand = model_compute_types.DispatchIndirectCommand;
    pub const KernelBinding = model_compute_types.KernelBinding;
    pub const KernelDispatchCommand = model_compute_types.KernelDispatchCommand;
    pub const MapAsyncCommand = model_async_types.MapAsyncCommand;
    pub const RenderDrawCommand = model_render_types.RenderDrawCommand;
    pub const SamplerCreateCommand = model_render_types.SamplerCreateCommand;
    pub const SamplerDestroyCommand = model_render_types.SamplerDestroyCommand;
    pub const TextureDestroyCommand = model_texture_types.TextureDestroyCommand;
    pub const TextureQueryCommand = model_texture_types.TextureQueryCommand;
    pub const TextureWriteCommand = model_texture_types.TextureWriteCommand;
    pub const UploadCommand = model_resource_types.UploadCommand;
};
const MANIFEST_STATUS_CODE_CAPACITY: usize = 256;
const STATUS_MESSAGE_BYTES: usize = 256;
const BOOTSTRAP_MANIFEST_MODULE = "bootstrap";
const BOOTSTRAP_MANIFEST_STATUS_CODE = "backend_initialized";

pub const ZigD3D12Backend = struct {
    allocator: std.mem.Allocator,
    kernel_root_owned: ?[]u8 = null,
    runtime: ?native_runtime.NativeD3D12Runtime = null,

    upload_buffer_usage_mode: webgpu.UploadBufferUsageMode = .copy_dst_copy_src,
    upload_submit_every: u32 = UPLOAD_BATCH_LAZY,
    queue_wait_mode: webgpu.QueueWaitMode = .process_events,
    queue_sync_mode: webgpu.QueueSyncMode = .per_command,
    gpu_timestamp_mode: webgpu.GpuTimestampMode = .auto,
    pending_upload_commands: u32 = 0,
    telemetry: runtime_telemetry.RuntimeTelemetry = backend_telemetry.default_telemetry(),

    capability_set: capabilities.CapabilitySet,
    status_message_storage: [STATUS_MESSAGE_BYTES]u8 = [_]u8{0} ** STATUS_MESSAGE_BYTES,
    status_message_len: usize = 0,

    manifest_emit_count: u64 = 0,
    manifest_path_storage: [MANIFEST_PATH_CAPACITY]u8 = std.mem.zeroes([MANIFEST_PATH_CAPACITY]u8),
    manifest_path_len: usize = 0,
    manifest_hash_storage: [HASH_HEX_SIZE]u8 = std.mem.zeroes([HASH_HEX_SIZE]u8),
    manifest_hash_len: usize = 0,
    last_manifest_meta: ?artifact_meta.ArtifactMeta = null,
    last_manifest_module_storage: [MANIFEST_MODULE_CAPACITY]u8 = std.mem.zeroes([MANIFEST_MODULE_CAPACITY]u8),
    last_manifest_module_len: usize = 0,
    last_manifest_status_storage: [MANIFEST_STATUS_CODE_CAPACITY]u8 = std.mem.zeroes([MANIFEST_STATUS_CODE_CAPACITY]u8),
    last_manifest_status_len: usize = 0,
    pending_artifact_write: bool = false,
    pending_artifact_module: []const u8 = "",
    pending_artifact_meta: artifact_meta.ArtifactMeta = undefined,
    pending_artifact_status_storage: [MANIFEST_STATUS_CODE_CAPACITY]u8 = std.mem.zeroes([MANIFEST_STATUS_CODE_CAPACITY]u8),
    pending_artifact_status_len: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        profile: model.DeviceProfile,
        kernel_root: ?[]const u8,
    ) !*ZigD3D12Backend {
        if (profile.api != .d3d12) return common_errors.BackendNativeError.UnsupportedFeature;
        if (builtin.os.tag != .windows) return common_errors.BackendNativeError.UnsupportedFeature;

        const owned_root = if (kernel_root) |root| try allocator.dupe(u8, root) else null;
        errdefer if (owned_root) |r| allocator.free(r);

        const ptr = try allocator.create(ZigD3D12Backend);
        errdefer allocator.destroy(ptr);

        ptr.* = .{
            .allocator = allocator,
            .kernel_root_owned = owned_root,
            .runtime = null,
            .upload_buffer_usage_mode = .copy_dst_copy_src,
            .upload_submit_every = UPLOAD_BATCH_LAZY,
            .queue_wait_mode = .process_events,
            .queue_sync_mode = .per_command,
            .gpu_timestamp_mode = .auto,
            .pending_upload_commands = 0,
            .telemetry = backend_telemetry.default_telemetry(),
            .capability_set = native_capability_set(),
            .status_message_storage = [_]u8{0} ** STATUS_MESSAGE_BYTES,
            .status_message_len = 0,
            .manifest_emit_count = 0,
            .manifest_path_storage = std.mem.zeroes([MANIFEST_PATH_CAPACITY]u8),
            .manifest_path_len = 0,
            .manifest_hash_storage = std.mem.zeroes([HASH_HEX_SIZE]u8),
            .manifest_hash_len = 0,
            .last_manifest_meta = null,
            .last_manifest_module_storage = std.mem.zeroes([MANIFEST_MODULE_CAPACITY]u8),
            .last_manifest_module_len = 0,
            .last_manifest_status_storage = std.mem.zeroes([MANIFEST_STATUS_CODE_CAPACITY]u8),
            .last_manifest_status_len = 0,
            .pending_artifact_write = false,
            .pending_artifact_module = "",
            .pending_artifact_meta = undefined,
            .pending_artifact_status_storage = std.mem.zeroes([MANIFEST_STATUS_CODE_CAPACITY]u8),
            .pending_artifact_status_len = 0,
        };

        ptr.emit_shader_artifact_manifest_for_signature(
            BOOTSTRAP_MANIFEST_MODULE,
            artifact_meta.classify(.native_d3d12, false, false),
            BOOTSTRAP_MANIFEST_STATUS_CODE,
        ) catch {};

        return ptr;
    }

    pub fn asPorts(
        self: *ZigD3D12Backend,
        reason: []const u8,
        policy_hash: []const u8,
        fallback_used: bool,
    ) port_factory.PortBundle {
        self.telemetry = backend_telemetry.forSelection(.doe_d3d12, reason, fallback_used, policy_hash);
        return provider_adapter.fromDriver(PortDriver, self, .doe_d3d12);
    }

    fn manifest_path(self: *const ZigD3D12Backend) ?[]const u8 {
        return artifact_emit.manifest_path(self);
    }

    fn manifest_hash(self: *const ZigD3D12Backend) ?[]const u8 {
        return artifact_emit.manifest_hash(self);
    }

    fn flush_pending_artifact(self: *ZigD3D12Backend) void {
        artifact_emit.flush_pending_artifact(self);
    }

    fn emit_shader_artifact_manifest_for_signature(
        self: *ZigD3D12Backend,
        module: []const u8,
        meta: artifact_meta.ArtifactMeta,
        status_code: []const u8,
    ) common_errors.BackendNativeError!void {
        return artifact_emit.emit_shader_artifact_manifest_for_signature(self, module, meta, status_code);
    }
};

fn native_capability_set() capabilities.CapabilitySet {
    var set = capabilities.CapabilitySet{};
    set.declare_all(&.{
        .buffer_upload,
        .barrier_sync,
        .kernel_dispatch,
        .compute_dispatch,
        .compute_dispatch_indirect,
        .buffer_copy,
        .sampler_lifecycle,
        .texture_write,
        .texture_query,
        .texture_destroy,
        .surface_lifecycle,
        .surface_present,
        .async_pipeline_diagnostics,
        .async_capability_introspection,
        .async_resource_table_immediates,
        .async_lifecycle_refcount,
        .async_pixel_local_storage,
        .map_async,
        .gpu_timestamps,
        .timestamp_inside_passes,
        .indirect_draw,
        .indexed_indirect_draw,
        .render_pass,
        .render_draw,
        .on_submitted_work_done,
        .device_limits,
        .device_features,
        .query_set,
        .depth_stencil,
        .texture_view,
        .descriptor_binding,
        .render_bundle,
    });
    return set;
}

fn write_status(self: *ZigD3D12Backend, comptime fmt: []const u8, args: anytype) []const u8 {
    const rendered = std.fmt.bufPrint(&self.status_message_storage, fmt, args) catch "status_format_error";
    self.status_message_len = rendered.len;
    return self.status_message_storage[0..self.status_message_len];
}

fn cast(ctx: *anyopaque) *ZigD3D12Backend {
    return @as(*ZigD3D12Backend, @ptrCast(@alignCast(ctx)));
}

pub fn manifest_path_from_context(ctx: *anyopaque) ?[]const u8 {
    const self = cast(ctx);
    self.flush_pending_artifact();
    return self.manifest_path();
}

pub fn manifest_hash_from_context(ctx: *anyopaque) ?[]const u8 {
    return cast(ctx).manifest_hash();
}

fn deinit(ctx: *anyopaque) void {
    const self = cast(ctx);
    const allocator = self.allocator;
    if (self.runtime) |*rt| {
        rt.deinit();
        self.runtime = null;
    }
    if (self.kernel_root_owned) |r| {
        allocator.free(r);
        self.kernel_root_owned = null;
    }
    allocator.destroy(self);
}

fn ensure_runtime_bootstrapped(self: *ZigD3D12Backend) !*native_runtime.NativeD3D12Runtime {
    if (self.runtime == null) {
        self.runtime = try native_runtime.NativeD3D12Runtime.init(self.allocator, self.kernel_root_owned);
    }
    return &self.runtime.?;
}

fn execute_upload(self: *ZigD3D12Backend, setup_ns: u64, upload: model.UploadCommand) !webgpu.NativeExecutionResult {
    const runtime = try ensure_runtime_bootstrapped(self);

    const encode_start = common_timing.now_ns();
    try runtime.upload_bytes(@as(u64, @intCast(upload.bytes)), self.upload_buffer_usage_mode);
    const encode_ns = common_timing.ns_delta(common_timing.now_ns(), encode_start);

    var submit_wait_ns: u64 = 0;
    self.pending_upload_commands +|= 1;
    if (self.pending_upload_commands >= self.upload_submit_every) {
        self.pending_upload_commands = 0;
        submit_wait_ns = try runtime.flush_queue();
    }

    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

fn execute_barrier(self: *ZigD3D12Backend, setup_ns: u64) !webgpu.NativeExecutionResult {
    const runtime = try ensure_runtime_bootstrapped(self);
    const submit_wait_ns = try runtime.barrier(self.queue_wait_mode);

    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = 0,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

fn execute_kernel_dispatch(self: *ZigD3D12Backend, setup_ns: u64, kd: model.KernelDispatchCommand) !webgpu.NativeExecutionResult {
    const runtime = try ensure_runtime_bootstrapped(self);
    const bytecode = try runtime.load_kernel_cso(self.allocator, kd.kernel);
    defer self.allocator.free(bytecode);
    try runtime.set_compute_shader(bytecode);

    var warmup_index: u32 = 0;
    while (warmup_index < kd.warmup_dispatch_count) : (warmup_index += 1) {
        _ = try runtime.run_dispatch(kd.x, kd.y, kd.z, 1, .per_command);
    }

    const metrics = try runtime.run_dispatch(kd.x, kd.y, kd.z, kd.repeat, self.queue_sync_mode);
    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = metrics.encode_ns,
        .submit_wait_ns = metrics.submit_wait_ns,
        .dispatch_count = metrics.dispatch_count,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

fn execute_compute_dispatch_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.DispatchCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const metrics = try rt.execute_compute_dispatch(cmd, self.queue_sync_mode);
    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = metrics.encode_ns,
        .submit_wait_ns = metrics.submit_wait_ns,
        .dispatch_count = metrics.dispatch_count,
    };
}

fn execute_dispatch_indirect_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.DispatchIndirectCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const metrics = try rt.execute_dispatch_indirect(cmd, self.queue_sync_mode);
    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = metrics.encode_ns,
        .submit_wait_ns = metrics.submit_wait_ns,
        .dispatch_count = metrics.dispatch_count,
    };
}

fn execute_copy_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.CopyCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const metrics = try rt.execute_copy(cmd, self.queue_sync_mode);
    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns +| metrics.setup_ns,
        .encode_ns = metrics.encode_ns,
        .submit_wait_ns = metrics.submit_wait_ns,
    };
}

fn execute_texture_write_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.TextureWriteCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const encode_ns = try rt.texture_write(cmd);
    return .{ .status = .ok, .status_message = "", .setup_ns = setup_ns, .encode_ns = encode_ns };
}

fn execute_texture_query_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.TextureQueryCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const encode_ns = try rt.texture_query(cmd);
    return .{ .status = .ok, .status_message = "", .setup_ns = setup_ns, .encode_ns = encode_ns };
}

fn execute_texture_destroy_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.TextureDestroyCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const encode_ns = try rt.texture_destroy(cmd);
    return .{ .status = .ok, .status_message = "", .setup_ns = setup_ns, .encode_ns = encode_ns };
}

fn execute_sampler_create_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.SamplerCreateCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const encode_ns = try rt.sampler_create(cmd);
    return .{ .status = .ok, .status_message = "", .setup_ns = setup_ns, .encode_ns = encode_ns };
}

fn execute_sampler_destroy_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.SamplerDestroyCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const encode_ns = try rt.sampler_destroy(cmd);
    return .{ .status = .ok, .status_message = "", .setup_ns = setup_ns, .encode_ns = encode_ns };
}

fn execute_render_draw_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.RenderDrawCommand, is_indirect: bool, is_indexed_indirect: bool) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const metrics = try rt.execute_render_draw(cmd, is_indirect, is_indexed_indirect, self.queue_sync_mode);
    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns +| metrics.setup_ns,
        .encode_ns = metrics.encode_ns,
        .submit_wait_ns = metrics.submit_wait_ns,
        .dispatch_count = metrics.draw_count,
    };
}

fn execute_surface_cmd(self: *ZigD3D12Backend, setup_ns: u64, command: model.Command) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const encode_ns: u64 = switch (command) {
        .surface_create => |cmd| try rt.surface_create(cmd),
        .surface_capabilities => |cmd| try rt.surface_capabilities(cmd),
        .surface_configure => |cmd| try rt.surface_configure(cmd),
        .surface_acquire => |cmd| try rt.surface_acquire(cmd),
        .surface_unconfigure => |cmd| try rt.surface_unconfigure(cmd),
        .surface_release => |cmd| try rt.surface_release(cmd),
        .surface_present => |cmd| {
            const submit_wait_ns = try rt.surface_present(cmd);
            return .{ .status = .ok, .status_message = "", .setup_ns = setup_ns, .submit_wait_ns = submit_wait_ns };
        },
        else => return error.Unsupported,
    };
    return .{ .status = .ok, .status_message = "", .setup_ns = setup_ns, .encode_ns = encode_ns };
}

fn execute_async_diagnostics_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.AsyncDiagnosticsCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const metrics = try rt.execute_async_diagnostics(cmd);
    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns +| metrics.setup_ns,
        .encode_ns = metrics.encode_ns,
    };
}

fn execute_map_async_cmd(self: *ZigD3D12Backend, setup_ns: u64, cmd: model.MapAsyncCommand) !webgpu.NativeExecutionResult {
    const rt = try ensure_runtime_bootstrapped(self);
    const encode_ns = try rt.execute_map_async(cmd);
    return .{ .status = .ok, .status_message = "", .setup_ns = setup_ns, .encode_ns = encode_ns };
}

fn flush_pending_uploads_if_required(self: *ZigD3D12Backend, command: model.Command) !u64 {
    switch (command) {
        .upload, .copy_buffer_to_texture => return 0,
        else => {},
    }
    const rt = try ensure_runtime_bootstrapped(self);
    const has_pending_uploads = self.pending_upload_commands > 0;
    const has_pending_copies = rt.streaming_copy_state.has_pending();
    if (!has_pending_uploads and !has_pending_copies) return 0;
    self.pending_upload_commands = 0;
    return try rt.flush_queue();
}

fn execute_native_command(
    self: *ZigD3D12Backend,
    command: model.Command,
    promoted_dispatch: ?compute_contract.DispatchRequest,
) !webgpu.NativeExecutionResult {
    const requirements = command_requirements.requirements(command);
    if (self.capability_set.missing(requirements.required_capabilities)) |missing_cap| {
        return .{
            .status = .unsupported,
            .status_message = capabilities.capability_name(missing_cap),
            .dispatch_count = if (requirements.is_dispatch) requirements.operation_count else 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    }

    var setup_ns: u64 = 0;
    if (self.runtime == null) {
        const setup_start = common_timing.now_ns();
        _ = try ensure_runtime_bootstrapped(self);
        setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);
    }

    const pending_submit_wait_ns = try flush_pending_uploads_if_required(self, command);

    var result = switch (command) {
        .upload => |upload| try execute_upload(self, setup_ns, upload),
        .buffer_write => return error.UnsupportedFeature,
        .barrier => try execute_barrier(self, setup_ns),
        .kernel_dispatch => try execute_kernel_dispatch(
            self,
            setup_ns,
            (promoted_dispatch orelse return error.InvalidArgument).toCommand(),
        ),
        .dispatch => |cmd| try execute_compute_dispatch_cmd(self, setup_ns, cmd),
        .dispatch_indirect => |cmd| try execute_dispatch_indirect_cmd(self, setup_ns, cmd),
        .copy_buffer_to_texture => |cmd| try execute_copy_cmd(self, setup_ns, cmd),
        .texture_write => |cmd| try execute_texture_write_cmd(self, setup_ns, cmd),
        .texture_query => |cmd| try execute_texture_query_cmd(self, setup_ns, cmd),
        .texture_destroy => |cmd| try execute_texture_destroy_cmd(self, setup_ns, cmd),
        .sampler_create => |cmd| try execute_sampler_create_cmd(self, setup_ns, cmd),
        .sampler_destroy => |cmd| try execute_sampler_destroy_cmd(self, setup_ns, cmd),
        .render_draw => |cmd| try execute_render_draw_cmd(self, setup_ns, cmd, false, false),
        .draw_indirect => |cmd| try execute_render_draw_cmd(self, setup_ns, cmd, true, false),
        .draw_indexed_indirect => |cmd| try execute_render_draw_cmd(self, setup_ns, cmd, false, true),
        .render_pass => |cmd| try execute_render_draw_cmd(self, setup_ns, cmd, false, false),
        .surface_create, .surface_capabilities, .surface_configure, .surface_acquire, .surface_present, .surface_unconfigure, .surface_release => try execute_surface_cmd(self, setup_ns, command),
        .async_diagnostics => |cmd| try execute_async_diagnostics_cmd(self, setup_ns, cmd),
        .map_async => |cmd| try execute_map_async_cmd(self, setup_ns, cmd),
    };
    result.submit_wait_ns +|= pending_submit_wait_ns;

    if (artifact_policy.should_emit_shader_artifact(command)) {
        const meta = artifact_meta.classify(
            .native_d3d12,
            result.gpu_timestamp_valid,
            result.gpu_timestamp_attempted,
        );
        const status_code = artifact_policy.artifact_status_code(result);
        const copy_len = @min(status_code.len, self.pending_artifact_status_storage.len);
        std.mem.copyForwards(u8, self.pending_artifact_status_storage[0..copy_len], status_code[0..copy_len]);
        self.pending_artifact_status_len = copy_len;
        self.pending_artifact_module = command_info.shader_artifact_module(command);
        self.pending_artifact_meta = meta;
        self.pending_artifact_write = true;
    }

    return result;
}

fn execute_command_typed(
    self: *ZigD3D12Backend,
    command: model.Command,
    promoted_dispatch: ?compute_contract.DispatchRequest,
) anyerror!webgpu.NativeExecutionResult {
    return execute_native_command(self, command, promoted_dispatch) catch |err| {
        const requirements = command_requirements.requirements(command);
        return .{
            .status = common_errors.map_error_status(err),
            .status_message = write_status(self, "{s}", .{common_errors.error_code(err)}),
            .dispatch_count = if (requirements.is_dispatch) requirements.operation_count else 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    };
}

fn execute_command(ctx: *anyopaque, command: model.Command) anyerror!webgpu.NativeExecutionResult {
    return execute_command_typed(cast(ctx), command, null);
}

fn execute_prepared_compute(ctx: *anyopaque, operation: prepared.PreparedComputeOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.toCommand());
}

fn execute_prepared_transfer(ctx: *anyopaque, operation: prepared.PreparedTransferOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.operation.toCommand().?);
}

fn execute_prepared_render(ctx: *anyopaque, operation: prepared.PreparedRenderOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.operation.toCommand());
}

fn execute_prepared_resource(ctx: *anyopaque, operation: prepared.PreparedResourceOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.operation.toCommand());
}

fn execute_prepared_surface(ctx: *anyopaque, operation: prepared.PreparedSurfaceOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.operation.toCommand());
}

fn execute_prepared_lifecycle(ctx: *anyopaque, operation: prepared.PreparedLifecycleOperation) anyerror!webgpu.NativeExecutionResult {
    return execute_command(ctx, operation.toCommand());
}

fn execute_dispatch(context: compute_contract.ComputeContext, request: compute_contract.DispatchRequest) anyerror!compute_contract.DispatchReport {
    const result = try execute_command_typed(
        cast(context.state),
        .{ .kernel_dispatch = request.toCommand() },
        request,
    );
    return .{ .execution = result };
}

fn execute_buffer_write_bytes(ctx: *anyopaque, handle: u64, offset: u64, buffer_size: u64, data: []const u8) anyerror!webgpu.NativeExecutionResult {
    _ = ctx;
    _ = handle;
    _ = offset;
    _ = buffer_size;
    _ = data;
    return error.UnsupportedFeature;
}

fn set_upload_behavior(ctx: *anyopaque, mode: webgpu.UploadBufferUsageMode, submit_every: u32) void {
    const self = cast(ctx);
    const normalized = if (submit_every == 0) @as(u32, 1) else submit_every;
    if (self.upload_buffer_usage_mode == mode and self.upload_submit_every == normalized) return;
    self.upload_buffer_usage_mode = mode;
    self.upload_submit_every = normalized;
}

fn set_queue_wait_mode(ctx: *anyopaque, mode: webgpu.QueueWaitMode) void {
    const self = cast(ctx);
    if (self.queue_wait_mode == mode) return;
    self.queue_wait_mode = mode;
}

fn set_webgpu_ffi_queue_wait_timeout_ns(ctx: *anyopaque, timeout_ns: u64) void {
    _ = ctx;
    _ = timeout_ns;
}

fn set_queue_sync_mode(ctx: *anyopaque, mode: webgpu.QueueSyncMode) void {
    const self = cast(ctx);
    if (self.queue_sync_mode == mode) return;
    self.queue_sync_mode = mode;
}

fn set_gpu_timestamp_mode(ctx: *anyopaque, mode: webgpu.GpuTimestampMode) void {
    const self = cast(ctx);
    if (self.gpu_timestamp_mode == mode) return;
    self.gpu_timestamp_mode = mode;
}

fn flush_queue(ctx: *anyopaque) anyerror!u64 {
    const self = cast(ctx);
    const rt = try ensure_runtime_bootstrapped(self);
    self.pending_upload_commands = 0;
    return try rt.flush_queue();
}

fn prewarm_upload_path(ctx: *anyopaque, max_upload_bytes: u64) anyerror!void {
    const self = cast(ctx);
    const rt = try ensure_runtime_bootstrapped(self);
    try rt.prewarm_upload_path(max_upload_bytes, self.upload_buffer_usage_mode);
}

fn prewarm_kernel_dispatch(
    ctx: *anyopaque,
    kernel: []const u8,
    entry_point: ?[]const u8,
    bindings: ?[]const model.KernelBinding,
    initialize_buffers_on_create: bool,
) anyerror!void {
    const self = cast(ctx);
    if (kernel.len == 0) return;
    const rt = try ensure_runtime_bootstrapped(self);
    _ = entry_point;
    _ = bindings;
    _ = initialize_buffers_on_create;
    const bytecode = rt.load_kernel_cso(self.allocator, kernel) catch return;
    defer self.allocator.free(bytecode);
    rt.set_compute_shader(bytecode) catch return;
}

fn capture_buffer(ctx: *anyopaque, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8 {
    _ = ctx;
    _ = allocator;
    _ = handle;
    _ = offset;
    _ = size;
    return error.UnsupportedFeature;
}

fn telemetry_snapshot(ctx: *anyopaque) runtime_telemetry.RuntimeTelemetry {
    const self = cast(ctx);
    self.telemetry.shader_artifact_manifest_path = manifest_path_from_context(ctx);
    self.telemetry.shader_artifact_manifest_hash = manifest_hash_from_context(ctx);
    return self.telemetry;
}

fn backend_id(ctx: *anyopaque) @import("../../contracts/backend.zig").BackendId {
    _ = ctx;
    return .doe_d3d12;
}

pub fn destroyContext(ctx: *anyopaque) void {
    deinit(ctx);
}

const PortDriver = struct {
    pub const backendId = backend_id;
    pub const executePreparedCompute = execute_prepared_compute;
    pub const executePreparedTransfer = execute_prepared_transfer;
    pub const executePreparedRender = execute_prepared_render;
    pub const executePreparedResource = execute_prepared_resource;
    pub const executePreparedSurface = execute_prepared_surface;
    pub const executePreparedLifecycle = execute_prepared_lifecycle;
    pub const executeDispatch = execute_dispatch;
    pub const executeBufferWrite = execute_buffer_write_bytes;
    pub const setUploadBehavior = set_upload_behavior;
    pub const setQueueWaitMode = set_queue_wait_mode;
    pub const setQueueWaitTimeoutNs = set_webgpu_ffi_queue_wait_timeout_ns;
    pub const setQueueSyncMode = set_queue_sync_mode;
    pub const setGpuTimestampMode = set_gpu_timestamp_mode;
    pub const flush = flush_queue;
    pub const prewarmUpload = prewarm_upload_path;
    pub const prewarmKernel = prewarm_kernel_dispatch;
    pub const capture = capture_buffer;
    pub const telemetrySnapshot = telemetry_snapshot;
};
