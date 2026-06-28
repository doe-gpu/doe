const std = @import("std");
const model_commands = @import("../../model_commands.zig");
const model_resource_types = @import("../../model_resource_types.zig");
const model_compute_types = @import("../../model_compute_types.zig");
const model_render_types = @import("../../model_render_types.zig");
const model_texture_types = @import("../../model_texture_types.zig");
const model_surface_control_types = @import("../../model_surface_control_types.zig");
const model_async_types = @import("../../model_async_types.zig");
const webgpu = @import("../runtime_types.zig");
const common_errors = @import("../common/errors.zig");
const common_timing = @import("../common/timing.zig");
const command_info = @import("../common/command_info.zig");
const command_requirements = @import("../common/command_requirements.zig");
const capabilities = @import("../common/capabilities.zig");
const artifact_meta = @import("../common/artifact_meta.zig");
const artifact_policy = @import("../common/artifact_policy.zig");
const submit_count_policy = @import("../common/submit_count_policy.zig");
const bridge = @import("metal_bridge_decls.zig");
const host_plan_artifact = @import("metal_host_plan_artifact.zig");

const model = struct {
    pub const AsyncDiagnosticsCommand = model_async_types.AsyncDiagnosticsCommand;
    pub const BufferWriteCommand = model_resource_types.BufferWriteCommand;
    pub const Command = model_commands.Command;
    pub const CopyCommand = model_resource_types.CopyCommand;
    pub const DispatchCommand = model_compute_types.DispatchCommand;
    pub const DispatchIndirectCommand = model_compute_types.DispatchIndirectCommand;
    pub const KernelBinding = model_compute_types.KernelBinding;
    pub const KernelDispatchCommand = model_compute_types.KernelDispatchCommand;
    pub const MapAsyncCommand = model_async_types.MapAsyncCommand;
    pub const RenderDrawCommand = model_render_types.RenderDrawCommand;
    pub const SamplerCreateCommand = model_render_types.SamplerCreateCommand;
    pub const SamplerDestroyCommand = model_render_types.SamplerDestroyCommand;
    pub const SurfaceAcquireCommand = model_surface_control_types.SurfaceAcquireCommand;
    pub const SurfaceCapabilitiesCommand = model_surface_control_types.SurfaceCapabilitiesCommand;
    pub const SurfaceConfigureCommand = model_surface_control_types.SurfaceConfigureCommand;
    pub const SurfaceCreateCommand = model_surface_control_types.SurfaceCreateCommand;
    pub const SurfacePresentCommand = model_surface_control_types.SurfacePresentCommand;
    pub const SurfaceReleaseCommand = model_surface_control_types.SurfaceReleaseCommand;
    pub const SurfaceUnconfigureCommand = model_surface_control_types.SurfaceUnconfigureCommand;
    pub const TextureDestroyCommand = model_texture_types.TextureDestroyCommand;
    pub const TextureQueryCommand = model_texture_types.TextureQueryCommand;
    pub const TextureWriteCommand = model_texture_types.TextureWriteCommand;
    pub const UploadCommand = model_resource_types.UploadCommand;
};

fn execute_upload(self: anytype, upload: model.UploadCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();

    if (self.gpu_timestamps_wanted()) rt.activate_gpu_timestamps() catch {};

    const setup_start = common_timing.now_ns();
    try rt.upload_bytes(@as(u64, @intCast(upload.bytes)), self.upload_buffer_usage_mode);
    const setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);

    self.pending_upload_commands +|= 1;

    var submit_wait_ns: u64 = 0;
    var gpu_ts_ns: u64 = 0;
    var gpu_ts_attempted = false;
    var gpu_ts_valid = false;
    if (self.queue_sync_mode == .per_command and self.pending_upload_commands >= self.upload_submit_every) {
        const flush = try rt.flush_queue_timed();
        submit_wait_ns = flush.submit_wait_ns;
        gpu_ts_ns = flush.gpu_elapsed_ns;
        gpu_ts_attempted = flush.gpu_timestamps_attempted;
        gpu_ts_valid = flush.gpu_timestamps_valid;
        self.pending_upload_commands = 0;
    }

    var r = self.ok_result(setup_ns, 0, submit_wait_ns, 0);
    r.gpu_timestamp_ns = gpu_ts_ns;
    r.gpu_timestamp_attempted = gpu_ts_attempted;
    r.gpu_timestamp_valid = gpu_ts_valid;
    return r;
}

fn execute_buffer_write(self: anytype, cmd: model.BufferWriteCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const setup_start = common_timing.now_ns();
    if (self.upload_path_policy == .staged_copy_only) {
        try rt.stage_buffer_write_bytes(cmd.handle, cmd.offset, cmd.buffer_size, std.mem.sliceAsBytes(cmd.data));
    } else {
        try rt.write_buffer(cmd);
    }
    const setup_end = common_timing.now_ns();

    self.pending_upload_commands +|= 1;
    var submit_wait_ns: u64 = 0;
    if (self.queue_sync_mode == .per_command and self.pending_upload_commands >= self.upload_submit_every) {
        submit_wait_ns = try rt.flush_queue();
        self.pending_upload_commands = 0;
    } else {
        rt.has_deferred_submissions = true;
    }

    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = common_timing.ns_delta(setup_end, setup_start),
        .encode_ns = 0,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

fn execute_buffer_write_bytes(self: anytype, handle: u64, offset: u64, buffer_size: u64, data: []const u8) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const setup_start = common_timing.now_ns();
    if (self.upload_path_policy == .staged_copy_only) {
        try rt.stage_buffer_write_bytes(handle, offset, buffer_size, data);
    } else {
        try rt.write_buffer_bytes(handle, offset, buffer_size, data);
    }
    const setup_end = common_timing.now_ns();

    self.pending_upload_commands +|= 1;
    var submit_wait_ns: u64 = 0;
    if (self.queue_sync_mode == .per_command and self.pending_upload_commands >= self.upload_submit_every) {
        submit_wait_ns = try rt.flush_queue();
        self.pending_upload_commands = 0;
    } else {
        rt.has_deferred_submissions = true;
    }

    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = common_timing.ns_delta(setup_end, setup_start),
        .encode_ns = 0,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

fn execute_barrier(self: anytype) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const submit_wait_ns = try rt.barrier(self.queue_wait_mode, self.queue_sync_mode);
    return self.ok_result(0, 0, submit_wait_ns, 0);
}

fn execute_dispatch(self: anytype, dispatch: model.DispatchCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const metrics = try rt.run_dispatch(dispatch.x, dispatch.y, dispatch.z, self.queue_sync_mode);
    return self.ok_result(0, metrics.encode_ns, metrics.submit_wait_ns, metrics.dispatch_count);
}

fn execute_dispatch_indirect(self: anytype, dispatch: model.DispatchIndirectCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const metrics = try rt.run_dispatch_indirect(dispatch.x, dispatch.y, dispatch.z, self.queue_sync_mode);
    return self.ok_result(0, metrics.encode_ns, metrics.submit_wait_ns, metrics.dispatch_count);
}

fn execute_kernel_dispatch(self: anytype, kd: model.KernelDispatchCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const want_ts = self.gpu_timestamps_wanted();
    const result = try rt.run_kernel_dispatch_timed(
        kd.kernel,
        kd.entry_point,
        kd.x,
        kd.y,
        kd.z,
        kd.repeat,
        kd.warmup_dispatch_count,
        kd.initialize_buffers_on_create,
        kd.bindings,
        self.queue_sync_mode,
        want_ts,
    );
    var r = self.ok_result(result.metrics.setup_ns, result.metrics.encode_ns, result.metrics.submit_wait_ns, result.metrics.dispatch_count);
    r.gpu_timestamp_ns = result.gpu_elapsed_ns;
    r.gpu_timestamp_attempted = result.gpu_timestamps_attempted;
    r.gpu_timestamp_valid = result.gpu_timestamps_valid;
    host_plan_artifact.emitForKernelDispatch(self, kd) catch {};
    return r;
}

fn execute_copy(self: anytype, cmd: model.CopyCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    if (self.gpu_timestamps_wanted()) rt.activate_gpu_timestamps() catch {};
    const metrics = try rt.copy_command(cmd, self.queue_sync_mode);
    var r = self.ok_result(metrics.setup_ns, metrics.encode_ns, metrics.submit_wait_ns, 0);
    r.gpu_timestamp_ns = metrics.gpu_elapsed_ns;
    r.gpu_timestamp_attempted = metrics.gpu_timestamps_attempted;
    r.gpu_timestamp_valid = metrics.gpu_timestamps_valid;
    return r;
}

fn execute_sampler_create(self: anytype, cmd: model.SamplerCreateCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.sampler_create(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_sampler_destroy(self: anytype, cmd: model.SamplerDestroyCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.sampler_destroy(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_texture_write(self: anytype, cmd: model.TextureWriteCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.texture_write(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_texture_query(self: anytype, cmd: model.TextureQueryCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.texture_query(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_texture_destroy(self: anytype, cmd: model.TextureDestroyCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.texture_destroy(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_surface_create(self: anytype, cmd: model.SurfaceCreateCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.surface_create(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_surface_capabilities(self: anytype, cmd: model.SurfaceCapabilitiesCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.surface_capabilities(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_surface_configure(self: anytype, cmd: model.SurfaceConfigureCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.surface_configure(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_surface_acquire(self: anytype, cmd: model.SurfaceAcquireCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.surface_acquire(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_surface_present(self: anytype, cmd: model.SurfacePresentCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const submit_wait_ns = try rt.surface_present(cmd);
    return self.ok_result(0, 0, submit_wait_ns, 0);
}

fn execute_surface_unconfigure(self: anytype, cmd: model.SurfaceUnconfigureCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.surface_unconfigure(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_surface_release(self: anytype, cmd: model.SurfaceReleaseCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_start = common_timing.now_ns();
    try rt.surface_release(cmd);
    return self.ok_result(0, common_timing.ns_delta(common_timing.now_ns(), encode_start), 0, 0);
}

fn execute_render_draw(self: anytype, cmd: model.RenderDrawCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    if (self.gpu_timestamps_wanted()) rt.activate_gpu_timestamps() catch {};
    const metrics = try rt.render_draw(cmd, self.queue_sync_mode);
    var r = self.ok_result(metrics.setup_ns, metrics.encode_ns, metrics.submit_wait_ns, metrics.draw_count);
    r.gpu_timestamp_ns = metrics.gpu_elapsed_ns;
    r.gpu_timestamp_attempted = metrics.gpu_timestamps_attempted;
    r.gpu_timestamp_valid = metrics.gpu_timestamps_valid;
    return r;
}

fn execute_async_diagnostics(self: anytype, cmd: model.AsyncDiagnosticsCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const setup_start = common_timing.now_ns();
    switch (cmd.mode) {
        .pipeline_async => {
            try rt.ensure_render_pipeline(cmd.target_format);
            const setup_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);
            return self.ok_result(setup_ns, 0, 0, 0);
        },
        else => {
            try rt.ensure_render_pipeline(cmd.target_format);
            const encode_ns = common_timing.ns_delta(common_timing.now_ns(), setup_start);
            return self.ok_result(0, encode_ns, 0, 1);
        },
    }
}

fn execute_map_async(self: anytype, cmd: model.MapAsyncCommand) !webgpu.NativeExecutionResult {
    const rt = self.get_runtime();
    const encode_ns = try rt.execute_map_async(cmd);
    return self.ok_result(0, encode_ns, 0, 0);
}

fn flush_pending_uploads_if_required(self: anytype, command: model.Command) !u64 {
    const rt = self.get_runtime();
    var submit_wait_ns: u64 = 0;
    const requires_compute_boundary = switch (command) {
        .dispatch, .dispatch_indirect, .kernel_dispatch => false,
        else => true,
    };
    if (requires_compute_boundary and rt.streaming_compute_encoder != null) {
        submit_wait_ns +|= try rt.flush_queue();
        self.pending_upload_commands = 0;
    }
    switch (command) {
        .upload, .barrier, .render_draw, .draw_indirect, .draw_indexed_indirect, .render_pass => return submit_wait_ns,
        else => {},
    }
    if (self.pending_upload_commands == 0) return submit_wait_ns;
    self.pending_upload_commands = 0;
    submit_wait_ns +|= try rt.flush_queue();
    return submit_wait_ns;
}

fn execute_native_command(self: anytype, command: model.Command) !webgpu.NativeExecutionResult {
    host_plan_artifact.clearHostPlanArtifact(self);
    try self.check_timestamp_requirement();

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

    const flush_start = common_timing.now_ns();
    const pending_submit_wait_ns = try flush_pending_uploads_if_required(self, command);
    const flush_setup_ns = common_timing.ns_delta(common_timing.now_ns(), flush_start) -| pending_submit_wait_ns;

    var result = switch (command) {
        .upload => |upload| try execute_upload(self, upload),
        .buffer_write => |cmd| try execute_buffer_write(self, cmd),
        .copy_buffer_to_texture => |copy| try execute_copy(self, copy),
        .barrier => try execute_barrier(self),
        .dispatch => |dispatch| try execute_dispatch(self, dispatch),
        .dispatch_indirect => |dispatch| try execute_dispatch_indirect(self, dispatch),
        .kernel_dispatch => |kd| try execute_kernel_dispatch(self, kd),
        .sampler_create => |cmd| try execute_sampler_create(self, cmd),
        .sampler_destroy => |cmd| try execute_sampler_destroy(self, cmd),
        .texture_write => |cmd| try execute_texture_write(self, cmd),
        .texture_query => |cmd| try execute_texture_query(self, cmd),
        .texture_destroy => |cmd| try execute_texture_destroy(self, cmd),
        .surface_create => |cmd| try execute_surface_create(self, cmd),
        .surface_capabilities => |cmd| try execute_surface_capabilities(self, cmd),
        .surface_configure => |cmd| try execute_surface_configure(self, cmd),
        .surface_acquire => |cmd| try execute_surface_acquire(self, cmd),
        .surface_present => |cmd| try execute_surface_present(self, cmd),
        .surface_unconfigure => |cmd| try execute_surface_unconfigure(self, cmd),
        .surface_release => |cmd| try execute_surface_release(self, cmd),
        .render_draw => |cmd| try execute_render_draw(self, cmd),
        .draw_indirect => |cmd| try execute_render_draw(self, cmd),
        .draw_indexed_indirect => |cmd| try execute_render_draw(self, cmd),
        .render_pass => |cmd| try execute_render_draw(self, cmd),
        .async_diagnostics => |cmd| try execute_async_diagnostics(self, cmd),
        .map_async => |cmd| try execute_map_async(self, cmd),
    };
    result.setup_ns +|= flush_setup_ns;
    result.submit_wait_ns +|= pending_submit_wait_ns;

    if (artifact_policy.should_emit_shader_artifact(command)) {
        const meta = artifact_meta.classify(
            .native_metal,
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

pub fn execute_command(self: anytype, command: model.Command) anyerror!webgpu.NativeExecutionResult {
    self.last_submit_count = null;
    const result = execute_native_command(self, command) catch |err| {
        const requirements = command_requirements.requirements(command);
        return .{
            .status = common_errors.map_error_status(err),
            .status_message = self.write_status("{s}", .{common_errors.error_code(err)}),
            .dispatch_count = if (requirements.is_dispatch) requirements.operation_count else 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    };
    self.last_submit_count = submit_count_policy.selectedCommandSubmitCount(command, result);
    return result;
}

pub fn execute_buffer_write_bytes_iface(self: anytype, handle: u64, offset: u64, buffer_size: u64, data: []const u8) anyerror!webgpu.NativeExecutionResult {
    self.last_submit_count = null;
    const result = execute_buffer_write_bytes(self, handle, offset, buffer_size, data) catch |err| {
        return .{
            .status = common_errors.map_error_status(err),
            .status_message = self.write_status("{s}", .{common_errors.error_code(err)}),
            .dispatch_count = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    };
    self.last_submit_count = submit_count_policy.selectedKindSubmitCount(.buffer_write, result);
    return result;
}

pub fn set_upload_behavior(self: anytype, mode: webgpu.UploadBufferUsageMode, submit_every: u32) void {
    const normalized = if (submit_every == 0) @as(u32, 1) else submit_every;
    const effective_mode = if (self.upload_path_policy == .staged_copy_only) webgpu.UploadBufferUsageMode.copy_dst else mode;
    if (self.upload_buffer_usage_mode == effective_mode and self.upload_submit_every == normalized) return;
    self.upload_buffer_usage_mode = effective_mode;
    self.upload_submit_every = normalized;
}

pub fn set_queue_wait_mode(self: anytype, mode: webgpu.QueueWaitMode) void {
    if (self.queue_wait_mode == mode) return;
    self.queue_wait_mode = mode;
}

pub fn set_queue_sync_mode(self: anytype, mode: webgpu.QueueSyncMode) void {
    if (self.queue_sync_mode == mode) return;
    self.queue_sync_mode = mode;
}

pub fn set_gpu_timestamp_mode(self: anytype, mode: webgpu.GpuTimestampMode) void {
    if (self.gpu_timestamp_mode == mode) return;
    self.gpu_timestamp_mode = mode;
}

pub fn flush_queue(self: anytype) anyerror!u64 {
    const rt = self.get_runtime();
    self.pending_upload_commands = 0;
    return try rt.flush_queue();
}

pub fn prewarm_upload_path(self: anytype, max_upload_bytes: u64) anyerror!void {
    const rt = self.get_runtime();
    try rt.prewarm_upload_path(max_upload_bytes, self.upload_buffer_usage_mode);
}

pub fn prewarm_kernel_dispatch(
    self: anytype,
    kernel: []const u8,
    entry_point: ?[]const u8,
    bindings: ?[]const model.KernelBinding,
    initialize_buffers_on_create: bool,
) anyerror!void {
    const rt = self.get_runtime();
    _ = try rt.ensure_kernel_pipeline(kernel, entry_point);
    if (bindings) |bs| {
        for (bs) |b| {
            if (b.resource_kind != .buffer) continue;
            _ = try rt.ensure_compute_buffer(
                b.resource_handle,
                b.buffer_size,
                initialize_buffers_on_create,
            );
        }
    }
}

pub fn capture_buffer(self: anytype, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8 {
    const runtime = self.get_runtime();
    if (size == 0) return error.InvalidArgument;
    const end = std.math.add(u64, offset, size) catch return error.InvalidArgument;
    const buffer = runtime.compute_buffers.get(handle) orelse return error.InvalidArgument;
    const mapped = bridge.metal_bridge_buffer_contents(buffer) orelse return error.InvalidState;
    const source = mapped[@intCast(offset)..@intCast(end)];
    return try allocator.dupe(u8, source);
}
