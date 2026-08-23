const std = @import("std");
const model_commands = @import("../../contracts/command.zig");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const compute_contract = @import("../../contracts/compute.zig");
const model_render_types = @import("../../contracts/model/model_render_types.zig");
const model_async_types = @import("../../contracts/model/model_async_types.zig");
const webgpu = @import("../../contracts/runtime_types.zig");
const common_errors = @import("../../contracts/execution.zig");
const common_timing = @import("../common/timing.zig");
const command_info = @import("../../contracts/command.zig");
const command_requirements = @import("../../contracts/command.zig");
const capabilities = @import("../../contracts/capability.zig");
const artifact_meta = @import("../../contracts/artifact.zig");
const artifact_policy = @import("../common/artifact_policy.zig");
const native_runtime = @import("native_runtime.zig");
const vk_async_dispatch = @import("vk_async_dispatch.zig");

const model = struct {
    pub const AsyncDiagnosticsCommand = model_async_types.AsyncDiagnosticsCommand;
    pub const BufferWriteCommand = model_resource_types.BufferWriteCommand;
    pub const Command = model_commands.Command;
    pub const KernelBinding = model_compute_types.KernelBinding;
    pub const KernelDispatchCommand = model_compute_types.KernelDispatchCommand;
    pub const RenderDrawCommand = model_render_types.RenderDrawCommand;
    pub const UploadCommand = model_resource_types.UploadCommand;
};

fn unsupported_capability_result(
    requirements: command_requirements.CommandRequirements,
    missing: capabilities.Capability,
) webgpu.NativeExecutionResult {
    return .{
        .status = .unsupported,
        .status_message = capabilities.capability_name(missing),
        .dispatch_count = if (requirements.is_dispatch) requirements.operation_count else 0,
    };
}

fn execute_upload(self: anytype, setup_ns: u64, upload: model.UploadCommand) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();

    const upload_setup_start = common_timing.now_ns();
    try runtime.upload_bytes(
        @as(u64, @intCast(upload.bytes)),
        self.upload_buffer_usage_mode,
        self.upload_path_policy,
    );
    const upload_setup_ns = common_timing.ns_delta(common_timing.now_ns(), upload_setup_start);

    var submit_wait_ns: u64 = 0;
    var submit_count: u32 = 0;
    self.pending_upload_commands +|= 1;
    if (self.pending_upload_commands >= self.upload_submit_every) {
        self.pending_upload_commands = 0;
        submit_wait_ns = try runtime.flush_queue();
        submit_count = if (submit_wait_ns > 0) 1 else 0;
    }
    runtime.last_submit_count = submit_count;

    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns +| upload_setup_ns,
        .encode_ns = 0,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

fn execute_barrier(self: anytype, setup_ns: u64) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();
    const submit_wait_ns = try runtime.barrier(self.queue_wait_mode);
    runtime.last_submit_count = if (submit_wait_ns > 0) 1 else 0;

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

fn execute_buffer_write(self: anytype, setup_ns: u64, bw: model.BufferWriteCommand) !webgpu.NativeExecutionResult {
    const data_bytes = std.mem.sliceAsBytes(bw.data);
    return execute_buffer_write_bytes(self, setup_ns, bw.handle, bw.offset, bw.buffer_size, data_bytes);
}

fn execute_buffer_write_bytes(self: anytype, setup_ns: u64, handle: u64, offset: u64, buffer_size: u64, data_bytes: []const u8) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();
    const write_start = common_timing.now_ns();
    if (data_bytes.len == 0) return error.InvalidArgument;

    const required_size = if (buffer_size > 0)
        @max(buffer_size, offset + data_bytes.len)
    else
        offset + data_bytes.len;

    const vk_resources = @import("vk_resources.zig");
    const compute_buffer = try vk_resources.ensure_compute_buffer(runtime, handle, required_size, false);
    try vk_resources.stage_compute_buffer_write(runtime, compute_buffer, offset, data_bytes, self.upload_path_policy);
    var submit_wait_ns: u64 = 0;
    var submit_count: u32 = 0;
    if (runtime.streaming_copy_active and self.queue_sync_mode == .per_command) {
        const submit_start = common_timing.now_ns();
        try runtime.flush_streaming_copy(true);
        submit_wait_ns = common_timing.ns_delta(common_timing.now_ns(), submit_start);
        submit_count = 1;
    } else if (runtime.streaming_copy_active) {
        submit_count = 1;
    }
    runtime.last_submit_count = submit_count;

    const write_ns = common_timing.ns_delta(common_timing.now_ns(), write_start);
    const status_message = switch (compute_buffer.memory_kind) {
        .host_visible => "buffer seeded via host-visible memcpy",
        .device_local => "buffer uploaded via staged copy",
    };

    return .{
        .status = .ok,
        .status_message = status_message,
        .setup_ns = setup_ns +| write_ns,
        .encode_ns = 0,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = 0,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

fn use_explicit_submit_boundaries(self: anytype) bool {
    _ = self;
    // Recorded-submit replay reduced row-local submit cost, but on long
    // dependent compute streams it regressed real wall time badly by pushing
    // the work into one large deferred drain. Keep native Vulkan on the true
    // per-command path until replay can prove a wall-time win.
    return false;
}

fn execute_dispatch_command(
    self: anytype,
    setup_ns: u64,
    x: u32,
    y: u32,
    z: u32,
    repeat: u32,
    repeat_synchronization: model_compute_types.KernelDispatchRepeatSynchronization,
    warmup_dispatch_count: u32,
) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();
    const explicit_submit_boundaries = use_explicit_submit_boundaries(self);
    const dispatch_sync_mode: webgpu.QueueSyncMode = if (explicit_submit_boundaries) .deferred else self.queue_sync_mode;
    const dispatch_gpu_timestamp_mode: webgpu.GpuTimestampMode = if (explicit_submit_boundaries) .off else self.gpu_timestamp_mode;
    const previous_replay_state = runtime.recorded_submit_replay_active;
    runtime.recorded_submit_replay_active = explicit_submit_boundaries;
    defer runtime.recorded_submit_replay_active = previous_replay_state;

    if (!runtime.has_pipeline) {
        const noop_words = try runtime.load_kernel_spirv_cached("dispatch_noop.wgsl");
        try runtime.set_compute_shader_spirv(noop_words, null, null, false);
    }

    var warmup_index: u32 = 0;
    while (warmup_index < warmup_dispatch_count) : (warmup_index += 1) {
        _ = try runtime.run_dispatch(
            x,
            y,
            z,
            if (explicit_submit_boundaries) .deferred else .per_command,
            self.queue_wait_mode,
            .off,
        );
    }
    if (explicit_submit_boundaries and warmup_dispatch_count > 0) {
        _ = try runtime.flush_queue();
    }

    const dispatch_count = if (repeat > 0) repeat else 1;

    if (dispatch_sync_mode == .per_command and dispatch_count > 1) {
        const metrics = try runtime.run_dispatch_repeat(
            x,
            y,
            z,
            dispatch_count,
            repeat_synchronization,
            self.queue_wait_mode,
            dispatch_gpu_timestamp_mode,
        );
        runtime.last_submit_count = metrics.submit_count;
        return .{
            .status = .ok,
            .status_message = "",
            .setup_ns = setup_ns,
            .encode_ns = metrics.encode_ns,
            .submit_wait_ns = metrics.submit_wait_ns,
            .dispatch_count = dispatch_count,
            .gpu_timestamp_ns = metrics.gpu_timestamp_ns,
            .gpu_timestamp_attempted = metrics.gpu_timestamp_attempted,
            .gpu_timestamp_valid = metrics.gpu_timestamp_valid,
        };
    }

    var encode_ns: u64 = 0;
    var submit_wait_ns: u64 = 0;
    var gpu_timestamp_ns: u64 = 0;
    var gpu_timestamp_attempted = false;
    var gpu_timestamp_valid = true;

    var dispatch_index: u32 = 0;
    while (dispatch_index < dispatch_count) : (dispatch_index += 1) {
        const metrics = try runtime.run_dispatch(
            x,
            y,
            z,
            dispatch_sync_mode,
            self.queue_wait_mode,
            dispatch_gpu_timestamp_mode,
        );

        runtime.last_submit_count = metrics.submit_count;
        encode_ns +|= metrics.encode_ns;
        submit_wait_ns +|= metrics.submit_wait_ns;

        gpu_timestamp_attempted = gpu_timestamp_attempted or metrics.gpu_timestamp_attempted;
        if (metrics.gpu_timestamp_attempted and metrics.gpu_timestamp_valid) {
            gpu_timestamp_ns +|= metrics.gpu_timestamp_ns;
        }
        if (metrics.gpu_timestamp_attempted and !metrics.gpu_timestamp_valid) {
            gpu_timestamp_valid = false;
        }
    }

    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = dispatch_count,
        .gpu_timestamp_ns = if (gpu_timestamp_attempted and gpu_timestamp_valid) gpu_timestamp_ns else 0,
        .gpu_timestamp_attempted = gpu_timestamp_attempted,
        .gpu_timestamp_valid = gpu_timestamp_attempted and gpu_timestamp_valid,
    };
}

fn execute_dispatch_indirect_command(
    self: anytype,
    setup_ns: u64,
    x: u32,
    y: u32,
    z: u32,
) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();
    const explicit_submit_boundaries = use_explicit_submit_boundaries(self);
    const previous_replay_state = runtime.recorded_submit_replay_active;
    runtime.recorded_submit_replay_active = explicit_submit_boundaries;
    defer runtime.recorded_submit_replay_active = previous_replay_state;

    if (!runtime.has_pipeline) {
        const noop_words = try runtime.load_kernel_spirv_cached("dispatch_noop.wgsl");
        try runtime.set_compute_shader_spirv(noop_words, null, null, false);
    }

    const metrics = try runtime.run_dispatch_indirect(
        x,
        y,
        z,
        if (explicit_submit_boundaries) .deferred else self.queue_sync_mode,
        self.queue_wait_mode,
    );
    runtime.last_submit_count = metrics.submit_count;

    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = metrics.encode_ns,
        .submit_wait_ns = metrics.submit_wait_ns,
        .dispatch_count = 1,
        .gpu_timestamp_ns = metrics.gpu_timestamp_ns,
        .gpu_timestamp_attempted = metrics.gpu_timestamp_attempted,
        .gpu_timestamp_valid = metrics.gpu_timestamp_valid,
    };
}

fn execute_kernel_dispatch(comptime Backend: type, self: *Backend, setup_ns: u64, request: compute_contract.DispatchRequest) !webgpu.NativeExecutionResult {
    const kernel_dispatch = request.toCommand();
    const runtime = try self.ensure_runtime_bootstrapped();
    const previous_replay_state = runtime.recorded_submit_replay_active;
    runtime.recorded_submit_replay_active = use_explicit_submit_boundaries(self);
    defer runtime.recorded_submit_replay_active = previous_replay_state;
    const spirv_words = runtime.ensure_kernel_spirv_cached(kernel_dispatch.kernel) catch |err| {
        if (err == error.UnsupportedFeature and std.mem.endsWith(u8, kernel_dispatch.kernel, ".wgsl")) {
            return .{
                .status = .unsupported,
                .status_message = self.write_status(
                    "missing Vulkan SPIR-V artifact for WGSL kernel {s}; add explicit .spv artifact in kernel-root",
                    .{kernel_dispatch.kernel},
                ),
                .setup_ns = setup_ns,
                .dispatch_count = if (kernel_dispatch.repeat > 0) kernel_dispatch.repeat else 1,
            };
        }
        return err;
    };
    try runtime.set_compute_shader_spirv(
        spirv_words,
        kernel_dispatch.entry_point,
        kernel_dispatch.bindings,
        kernel_dispatch.initialize_buffers_on_create,
    );

    return execute_dispatch_command(
        self,
        setup_ns,
        kernel_dispatch.x,
        kernel_dispatch.y,
        kernel_dispatch.z,
        kernel_dispatch.repeat,
        kernel_dispatch.repeat_synchronization,
        kernel_dispatch.warmup_dispatch_count,
    );
}

fn execute_render_draw_command(
    self: anytype,
    setup_ns: u64,
    render_draw: model.RenderDrawCommand,
) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();
    const metrics = try runtime.run_render_draw(render_draw);
    const draw_count = if (render_draw.draw_count > 0) render_draw.draw_count else 1;

    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = metrics.encode_ns,
        .submit_wait_ns = metrics.submit_wait_ns,
        .dispatch_count = draw_count,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

fn execute_async_diagnostics(
    self: anytype,
    setup_ns: u64,
    diagnostics: model.AsyncDiagnosticsCommand,
) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();
    return vk_async_dispatch.execute(runtime, self.allocator, setup_ns, diagnostics, self.upload_path_policy);
}

fn execute_surface_command(self: anytype, setup_ns: u64, command: model.Command) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();
    const start_ns = common_timing.now_ns();
    switch (command) {
        .surface_create => |cmd| try runtime.create_surface(cmd.handle),
        .surface_capabilities => |cmd| try runtime.get_surface_capabilities(cmd.handle),
        .surface_configure => |cmd| try runtime.configure_surface(cmd),
        .surface_acquire => |cmd| try runtime.acquire_surface(cmd.handle),
        .surface_present => |cmd| try runtime.present_surface(cmd.handle),
        .surface_unconfigure => |cmd| try runtime.unconfigure_surface(cmd.handle),
        .surface_release => |cmd| try runtime.release_surface(cmd.handle),
        else => return error.InvalidArgument,
    }
    return result_without_gpu_timestamps(setup_ns, common_timing.ns_delta(common_timing.now_ns(), start_ns), 0, 0);
}

fn execute_sampler_command(self: anytype, setup_ns: u64, command: model.Command) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();
    const start_ns = common_timing.now_ns();
    switch (command) {
        .sampler_create => |cmd| try runtime.sampler_create(cmd),
        .sampler_destroy => |cmd| try runtime.sampler_destroy(cmd),
        else => return error.InvalidArgument,
    }
    return result_without_gpu_timestamps(setup_ns, common_timing.ns_delta(common_timing.now_ns(), start_ns), 0, 0);
}

fn execute_texture_command(self: anytype, setup_ns: u64, command: model.Command) !webgpu.NativeExecutionResult {
    const runtime = try self.ensure_runtime_bootstrapped();
    const start_ns = common_timing.now_ns();
    switch (command) {
        .texture_write => |cmd| try runtime.texture_write(cmd),
        .texture_query => |cmd| try runtime.texture_query(cmd),
        .texture_destroy => |cmd| try runtime.texture_destroy(cmd),
        else => return error.InvalidArgument,
    }
    return result_without_gpu_timestamps(setup_ns, common_timing.ns_delta(common_timing.now_ns(), start_ns), 0, 0);
}

fn result_without_gpu_timestamps(setup_ns: u64, encode_ns: u64, submit_wait_ns: u64, dispatch_count: u32) webgpu.NativeExecutionResult {
    return .{
        .status = .ok,
        .status_message = "",
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = dispatch_count,
        .gpu_timestamp_ns = 0,
        .gpu_timestamp_attempted = false,
        .gpu_timestamp_valid = false,
    };
}

fn flush_pending_uploads_if_required(comptime Backend: type, self: *Backend, command: model.Command) !u64 {
    switch (command) {
        .upload => return 0,
        else => {},
    }
    if (self.pending_upload_commands == 0) return 0;
    const runtime = try self.ensure_runtime_bootstrapped();
    self.pending_upload_commands = 0;
    return try runtime.flush_queue();
}

fn flush_pending_buffer_writes_if_required(comptime Backend: type, self: *Backend, command: model.Command) !u64 {
    switch (command) {
        .buffer_write => return 0,
        else => {},
    }
    if (self.runtime == null) return 0;
    const runtime = try self.ensure_runtime_bootstrapped();
    if (!runtime.streaming_copy_active) return 0;
    const submit_start = common_timing.now_ns();
    try runtime.flush_streaming_copy(true);
    return common_timing.ns_delta(common_timing.now_ns(), submit_start);
}

fn execute_runtime_command(
    comptime Backend: type,
    self: *Backend,
    command: model.Command,
    promoted_dispatch: ?compute_contract.DispatchRequest,
) !webgpu.NativeExecutionResult {
    const requirements = command_requirements.requirements(command);
    if (self.capability_set.missing(requirements.required_capabilities)) |missing| {
        return unsupported_capability_result(requirements, missing);
    }

    var setup_ns: u64 = 0;
    if (self.runtime == null) {
        const setup_start = common_timing.now_ns();
        _ = try self.ensure_runtime_bootstrapped();
        const setup_end = common_timing.now_ns();
        setup_ns = common_timing.ns_delta(setup_end, setup_start);
    }

    const flush_start = common_timing.now_ns();
    const pending_submit_wait_ns = try flush_pending_uploads_if_required(Backend, self, command);
    const pending_buffer_write_submit_wait_ns = try flush_pending_buffer_writes_if_required(Backend, self, command);
    const flush_setup_ns =
        common_timing.ns_delta(common_timing.now_ns(), flush_start) -| pending_submit_wait_ns -| pending_buffer_write_submit_wait_ns;

    var result = switch (command) {
        .upload => |upload| try execute_upload(self, setup_ns, upload),
        .buffer_write => |bw| try execute_buffer_write(self, setup_ns, bw),
        .barrier => try execute_barrier(self, setup_ns),
        .dispatch => |dispatch| try execute_dispatch_command(self, setup_ns, dispatch.x, dispatch.y, dispatch.z, 1, .dependent, 0),
        .dispatch_indirect => |dispatch| try execute_dispatch_indirect_command(self, setup_ns, dispatch.x, dispatch.y, dispatch.z),
        .kernel_dispatch => try execute_kernel_dispatch(
            @TypeOf(self.*),
            self,
            setup_ns,
            promoted_dispatch orelse return error.InvalidArgument,
        ),
        .render_draw => |render_draw| try execute_render_draw_command(self, setup_ns, render_draw),
        .draw_indirect => |render_draw| try execute_render_draw_command(self, setup_ns, render_draw),
        .draw_indexed_indirect => |render_draw| try execute_render_draw_command(self, setup_ns, render_draw),
        .render_pass => |render_draw| try execute_render_draw_command(self, setup_ns, render_draw),
        .async_diagnostics => |diagnostics| try execute_async_diagnostics(self, setup_ns, diagnostics),
        .sampler_create, .sampler_destroy => try execute_sampler_command(self, setup_ns, command),
        .texture_write,
        .texture_query,
        .texture_destroy,
        => try execute_texture_command(self, setup_ns, command),
        .surface_create,
        .surface_capabilities,
        .surface_configure,
        .surface_acquire,
        .surface_present,
        .surface_unconfigure,
        .surface_release,
        => try execute_surface_command(self, setup_ns, command),
        else => return error.Unsupported,
    };
    result.setup_ns +|= flush_setup_ns;
    result.submit_wait_ns +|= pending_submit_wait_ns;
    result.submit_wait_ns +|= pending_buffer_write_submit_wait_ns;

    return self.annotate_result(command, result);
}

pub fn execute_command(self: anytype, command: model.Command) anyerror!webgpu.NativeExecutionResult {
    const requirements = command_requirements.requirements(command);
    return execute_runtime_command(@TypeOf(self.*), self, command, null) catch |err| {
        return .{
            .status = common_errors.map_error_status(err),
            .status_message = self.write_status("{s}", .{common_errors.error_code(err)}),
            .setup_ns = 0,
            .encode_ns = 0,
            .submit_wait_ns = 0,
            .dispatch_count = if (requirements.is_dispatch) requirements.operation_count else 0,
            .gpu_timestamp_ns = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    };
}

pub fn execute_dispatch(comptime Backend: type, self: *Backend, request: compute_contract.DispatchRequest) anyerror!webgpu.NativeExecutionResult {
    const command = model.Command{ .kernel_dispatch = request.toCommand() };
    const requirements = command_requirements.requirements(command);
    return execute_runtime_command(Backend, self, command, request) catch |err| {
        return .{
            .status = common_errors.map_error_status(err),
            .status_message = self.write_status("{s}", .{common_errors.error_code(err)}),
            .setup_ns = 0,
            .encode_ns = 0,
            .submit_wait_ns = 0,
            .dispatch_count = if (requirements.is_dispatch) requirements.operation_count else 0,
            .gpu_timestamp_ns = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    };
}

pub fn execute_buffer_write_bytes_iface(self: anytype, handle: u64, offset: u64, buffer_size: u64, data: []const u8) anyerror!webgpu.NativeExecutionResult {
    return execute_buffer_write_bytes(self, 0, handle, offset, buffer_size, data) catch |err| {
        return .{
            .status = common_errors.map_error_status(err),
            .status_message = self.write_status("{s}", .{common_errors.error_code(err)}),
            .setup_ns = 0,
            .encode_ns = 0,
            .submit_wait_ns = 0,
            .dispatch_count = 0,
            .gpu_timestamp_ns = 0,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    };
}

pub fn set_upload_behavior(self: anytype, mode: webgpu.UploadBufferUsageMode, submit_every: u32) void {
    const normalized_submit_every = if (submit_every > 0) submit_every else 1;
    if (self.upload_buffer_usage_mode == mode and self.upload_submit_every == normalized_submit_every) return;
    self.upload_buffer_usage_mode = mode;
    self.upload_submit_every = normalized_submit_every;
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
    const runtime = try self.ensure_runtime_bootstrapped();
    self.pending_upload_commands = 0;
    return try runtime.flush_queue();
}

pub fn prewarm_upload_path(self: anytype, max_upload_bytes: u64) anyerror!void {
    const runtime = try self.ensure_runtime_bootstrapped();
    try runtime.prewarm_execution_bootstrap(self.gpu_timestamp_mode);
    try runtime.prewarm_upload_path(max_upload_bytes, self.upload_buffer_usage_mode, self.upload_path_policy);
}

pub fn prewarm_kernel_dispatch(
    self: anytype,
    kernel: []const u8,
    entry_point: ?[]const u8,
    bindings: ?[]const model.KernelBinding,
    initialize_buffers_on_create: bool,
) anyerror!void {
    const runtime = try self.ensure_runtime_bootstrapped();
    const spirv_words = try runtime.ensure_kernel_spirv_cached(kernel);
    try runtime.set_compute_shader_spirv(
        spirv_words,
        entry_point,
        bindings,
        initialize_buffers_on_create,
    );
}

pub fn capture_buffer(self: anytype, allocator: std.mem.Allocator, handle: u64, offset: u64, size: u64) anyerror![]u8 {
    const runtime = try self.ensure_runtime_bootstrapped();
    if (runtime.streaming_copy_active or runtime.has_deferred_submissions or runtime.hot_pending_upload != null or runtime.pending_uploads.items.len > 0) {
        _ = try runtime.flush_queue();
    }
    if (size == 0) return error.InvalidArgument;
    const buffer = runtime.compute_buffers.get(handle) orelse return error.InvalidArgument;
    try runtime.make_compute_writes_visible_for_capture(buffer.memory_kind);
    const vk_resources = @import("vk_resources.zig");
    return try vk_resources.capture_compute_buffer(runtime, allocator, buffer, offset, size);
}
