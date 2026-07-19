const std = @import("std");
const model_resource_types = @import("../../contracts/model/model_resource_types.zig");
const model_compute_types = @import("../../contracts/model/model_compute_types.zig");
const model_gpu_types = @import("../../contracts/model/model_binding_value_types.zig");
const proc_types = @import("../abi/wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const abi_execution = @import("../abi/wgpu_execution_types.zig");
const abi_records = @import("../abi/wgpu_runtime_records.zig");
const runtime_state = @import("../abi/wgpu_runtime_state_defs.zig");
const loader = @import("../abi/wgpu_loader.zig");
const p0_procs_mod = @import("../abi/procs/wgpu_p0_procs.zig");
const resources = @import("../resource/wgpu_resources.zig");

const BARRIER_SCRATCH_BUFFER_HANDLE: u64 = 0xFFFF_FFFF_FFFF_FFFB;
const DISPATCH_INDIRECT_ARGS_HANDLE: u64 = 0xFFFF_FFFF_FFFF_FFFA;
const BUFFER_USAGE_INDIRECT: abi_base.WGPUBufferUsage = 0x0000000000000100;
const MAX_KERNEL_SOURCE_BYTES: usize = 4 * 1024 * 1024;
const WHOLE_BUFFER_BINDING_MIN_BYTES: u64 = 4;
const DEFAULT_DISPATCH_WGSL_KERNEL = "dispatch_noop.wgsl";

pub fn executeBarrier(self: anytype, barrier: model_resource_types.BarrierCommand) !abi_execution.NativeExecutionResult {
    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const p0_procs = p0_procs_mod.loadP0Procs(self.core.dyn_lib);
    const clear_buffer = if (p0_procs) |loaded| loaded.command_encoder_clear_buffer else null;
    if (clear_buffer == null) {
        return .{
            .status = .unsupported,
            .status_message = "barrier command requires commandEncoderClearBuffer support",
        };
    }
    const clear_size = loader.alignTo(@max(@as(u64, 16), @as(u64, barrier.dependency_count) * 16), 4);
    const scratch_buffer = try resources.getOrCreateBuffer(
        self,
        BARRIER_SCRATCH_BUFFER_HANDLE,
        clear_size,
        abi_base.WGPUBufferUsage_CopyDst,
    );
    const encoder = procs.wgpuDeviceCreateCommandEncoder(self.core.device.?, &abi_descriptor.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (encoder == null) {
        return .{ .status = .@"error", .status_message = "deviceCreateCommandEncoder returned null" };
    }
    defer procs.wgpuCommandEncoderRelease(encoder);
    clear_buffer.?(encoder, scratch_buffer, 0, clear_size);
    const command_buffer = procs.wgpuCommandEncoderFinish(encoder, &abi_descriptor.WGPUCommandBufferDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (command_buffer == null) {
        return .{ .status = .@"error", .status_message = "commandEncoderFinish returned null" };
    }
    defer procs.wgpuCommandBufferRelease(command_buffer);
    var commands = [_]abi_base.WGPUCommandBuffer{command_buffer};
    const submit_wait_ns = try self.submitCommandBuffers(commands[0..]);
    return .{
        .status = .ok,
        .status_message = "barrier command lowered via commandEncoderClearBuffer",
        .submit_wait_ns = submit_wait_ns,
    };
}

pub fn executeDispatch(self: anytype, dispatch: model_compute_types.DispatchCommand) !abi_execution.NativeExecutionResult {
    return executeKernelDispatchKernel(
        self,
        DEFAULT_DISPATCH_WGSL_KERNEL,
        "main",
        dispatch.x,
        dispatch.y,
        dispatch.z,
        1,
        0,
        false,
        try resolveKernelSource(self, DEFAULT_DISPATCH_WGSL_KERNEL),
        null,
    );
}

pub fn executeDispatchIndirect(self: anytype, dispatch: model_compute_types.DispatchIndirectCommand) !abi_execution.NativeExecutionResult {
    return executeKernelDispatchKernel(
        self,
        DEFAULT_DISPATCH_WGSL_KERNEL,
        "main",
        dispatch.x,
        dispatch.y,
        dispatch.z,
        1,
        0,
        false,
        try resolveKernelSource(self, DEFAULT_DISPATCH_WGSL_KERNEL),
        null,
    );
}

pub fn executeKernelDispatch(self: anytype, kernel: model_compute_types.KernelDispatchCommand) !abi_execution.NativeExecutionResult {
    const source = resolveKernelSource(self, kernel.kernel) catch |err| {
        const message = switch (err) {
            error.MissingKernelSource => "kernel_dispatch has no resolvable WGSL source",
        };
        return .{ .status = .unsupported, .status_message = message };
    };
    const entry_point = kernel.entry_point orelse "main";
    return executeKernelDispatchKernel(
        self,
        kernel.kernel,
        entry_point,
        kernel.x,
        kernel.y,
        kernel.z,
        kernel.repeat,
        kernel.warmup_dispatch_count,
        kernel.initialize_buffers_on_create,
        source,
        kernel.bindings,
    );
}

pub fn pipelineCacheKey(source_bytes: []const u8, entry_point: []const u8) u64 {
    var h: u64 = 0x9e3779b97f4a7c15;
    for (source_bytes) |b| {
        h = (h ^ b) *% 0x517cc1b727220a95;
    }
    h ^= 0xff;
    for (entry_point) |b| {
        h = (h ^ b) *% 0x517cc1b727220a95;
    }
    return h;
}

pub fn executeKernelDispatchKernel(
    self: anytype,
    kernel_name: []const u8,
    entry_point: []const u8,
    x: u32,
    y: u32,
    z: u32,
    repeat_count: u32,
    warmup_dispatch_count: u32,
    initialize_buffers_on_create: bool,
    source: runtime_state.KernelSource,
    bindings: ?[]const model_compute_types.KernelBinding,
) !abi_execution.NativeExecutionResult {
    const setup_start_ns = std.time.nanoTimestamp();
    defer if (source.owned) self.core.allocator.free(source.source);
    if (!sourceContainsComputeStage(source.source)) {
        return .{
            .status = .unsupported,
            .status_message = "kernel source missing @compute stage",
        };
    }

    const procs = self.core.procs orelse return error.ProceduralNotReady;
    const p0_procs = p0_procs_mod.loadP0Procs(self.core.dyn_lib);

    const cache_key = pipelineCacheKey(source.source, entry_point);
    const cached = self.core.pipeline_cache.get(cache_key);

    var artifacts: ?abi_records.DispatchPassArtifacts = null;
    if (bindings) |bound| {
        if (bound.len > 0) {
            if (validateKernelBindingsAgainstLimits(self, bound)) |status_message| {
                return .{
                    .status = .@"error",
                    .status_message = status_message,
                };
            }
            artifacts = try resources.buildDispatchPassGroups(self, bound, initialize_buffers_on_create);
        }
    }
    defer {
        if (artifacts) |dispatch_artifacts| {
            for (dispatch_artifacts.texture_views) |texture_view| {
                procs.wgpuTextureViewRelease(texture_view);
            }
            self.core.allocator.free(dispatch_artifacts.texture_views);

            for (dispatch_artifacts.pass_bind_groups) |bind_group| {
                if (bind_group) |bound_group| {
                    procs.wgpuBindGroupRelease(bound_group);
                }
            }
            self.core.allocator.free(dispatch_artifacts.pass_bind_groups);

            for (dispatch_artifacts.group_layouts) |group_layout| {
                procs.wgpuBindGroupLayoutRelease(group_layout);
            }
            self.core.allocator.free(dispatch_artifacts.group_layouts);
        }
    }

    var pipeline_layout: abi_base.WGPUPipelineLayout = null;
    var owns_pipeline_layout = false;
    if (cached == null) {
        if (artifacts) |dispatch_artifacts| {
            if (dispatch_artifacts.group_layouts.len > 0) {
                pipeline_layout = try resources.createPipelineLayout(self, dispatch_artifacts.group_layouts);
                owns_pipeline_layout = true;
            }
        }
    }
    defer if (owns_pipeline_layout) if (pipeline_layout) |layout| procs.wgpuPipelineLayoutRelease(layout);

    const shader_module = if (cached) |hit| hit.shader_module else resources.createShaderModule(self, source.source) catch |err| {
        return .{
            .status = .@"error",
            .status_message = switch (err) {
                error.KernelModuleCreationFailed => "shader module creation returned null",
                error.ProceduralNotReady => "backend not ready",
            },
        };
    };

    const pipeline = if (cached) |hit| hit.pipeline else resources.createComputePipeline(self, kernel_name, shader_module, entry_point, pipeline_layout) catch {
        procs.wgpuShaderModuleRelease(shader_module);
        return .{ .status = .@"error", .status_message = "compute pipeline creation failed" };
    };

    if (cached == null) {
        self.core.pipeline_cache.put(cache_key, .{
            .shader_module = shader_module,
            .pipeline = pipeline,
        }) catch {};
    }

    const use_timestamps = self.gpuTimestampsEnabled();
    const timestamps_required = self.gpuTimestampsRequired();
    if (timestamps_required and !self.core.has_timestamp_query) {
        return .{
            .status = .@"error",
            .status_message = "gpu timestamp required but feature unavailable",
            .dispatch_count = repeat_count,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    }
    self.timestampLog(
        "dispatch kernel={s} repeat={} adapter_timestamp_query={} device_timestamp_query={}\n",
        .{ kernel_name, repeat_count, self.core.adapter_has_timestamp_query, self.core.has_timestamp_query },
    );
    var query_set: abi_base.WGPUQuerySet = null;
    var resolve_buffer: abi_base.WGPUBuffer = null;
    var readback_buffer: abi_base.WGPUBuffer = null;
    const dispatch_indirect_proc = if (p0_procs) |loaded| loaded.compute_pass_encoder_dispatch_workgroups_indirect else null;
    const command_encoder_write_buffer = if (p0_procs) |loaded| loaded.command_encoder_write_buffer else null;
    const compute_pass_write_timestamp = if (p0_procs) |loaded| loaded.compute_pass_encoder_write_timestamp else null;
    var dispatch_indirect_buffer: abi_base.WGPUBuffer = null;

    if (use_timestamps) {
        query_set = procs.wgpuDeviceCreateQuerySet(self.core.device.?, &abi_descriptor.WGPUQuerySetDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
            .type = abi_base.WGPUQueryType_Timestamp,
            .count = 2,
        });
        if (query_set != null) {
            if (!p0_procs_mod.querySetMatches(p0_procs, query_set, 2, abi_base.WGPUQueryType_Timestamp)) {
                p0_procs_mod.destroyQuerySet(p0_procs, query_set);
                procs.wgpuQuerySetRelease(query_set);
                query_set = null;
            }
        }
        if (query_set != null) {
            resolve_buffer = procs.wgpuDeviceCreateBuffer(self.core.device.?, &abi_descriptor.WGPUBufferDescriptor{
                .nextInChain = null,
                .label = loader.emptyStringView(),
                .usage = abi_base.WGPUBufferUsage_QueryResolve | abi_base.WGPUBufferUsage_CopySrc,
                .size = abi_base.TIMESTAMP_BUFFER_SIZE,
                .mappedAtCreation = abi_base.WGPU_FALSE,
            });
            readback_buffer = procs.wgpuDeviceCreateBuffer(self.core.device.?, &abi_descriptor.WGPUBufferDescriptor{
                .nextInChain = null,
                .label = loader.emptyStringView(),
                .usage = abi_base.WGPUBufferUsage_MapRead | abi_base.WGPUBufferUsage_CopyDst,
                .size = abi_base.TIMESTAMP_BUFFER_SIZE,
                .mappedAtCreation = abi_base.WGPU_FALSE,
            });
        }
    }
    if (dispatch_indirect_proc != null and command_encoder_write_buffer != null) {
        dispatch_indirect_buffer = resources.getOrCreateBuffer(
            self,
            DISPATCH_INDIRECT_ARGS_HANDLE,
            @sizeOf([3]u32),
            BUFFER_USAGE_INDIRECT | abi_base.WGPUBufferUsage_CopyDst,
        ) catch null;
    }
    const timestamps_active = query_set != null and resolve_buffer != null and readback_buffer != null;
    self.timestampLog(
        "timestamp_artifacts qs={} resolve={} readback={} active={}\n",
        .{ query_set != null, resolve_buffer != null, readback_buffer != null, timestamps_active },
    );
    if (!use_timestamps) {
        self.timestampLog("timestamp_path_disabled feature_unavailable\n", .{});
    } else if (!timestamps_active) {
        self.timestampLog(
            "timestamp_artifacts query_set={} resolve_buffer={} readback_buffer={}\n",
            .{ query_set != null, resolve_buffer != null, readback_buffer != null },
        );
    }
    if (timestamps_required and !timestamps_active) {
        return .{
            .status = .@"error",
            .status_message = "gpu timestamp required but artifacts unavailable",
            .dispatch_count = repeat_count,
            .gpu_timestamp_attempted = false,
            .gpu_timestamp_valid = false,
        };
    }
    defer {
        if (query_set) |qs| {
            p0_procs_mod.destroyQuerySet(p0_procs, qs);
            procs.wgpuQuerySetRelease(qs);
        }
        if (resolve_buffer) |buf| procs.wgpuBufferRelease(buf);
        if (readback_buffer) |buf| procs.wgpuBufferRelease(buf);
    }

    if (warmup_dispatch_count > 0) {
        const warmup_encoder = procs.wgpuDeviceCreateCommandEncoder(self.core.device.?, &abi_descriptor.WGPUCommandEncoderDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
        });
        if (warmup_encoder == null) {
            return .{ .status = .@"error", .status_message = "warmup deviceCreateCommandEncoder returned null" };
        }
        defer procs.wgpuCommandEncoderRelease(warmup_encoder);

        if (dispatch_indirect_proc != null and command_encoder_write_buffer != null and dispatch_indirect_buffer != null) {
            const dispatch_args = [3]u32{ x, y, z };
            const dispatch_args_bytes = std.mem.asBytes(&dispatch_args);
            command_encoder_write_buffer.?(warmup_encoder, dispatch_indirect_buffer, 0, dispatch_args_bytes.ptr, @as(u64, dispatch_args_bytes.len));
        }

        const warmup_pass = procs.wgpuCommandEncoderBeginComputePass(
            warmup_encoder,
            &abi_descriptor.WGPUComputePassDescriptor{
                .nextInChain = null,
                .label = loader.emptyStringView(),
                .timestampWrites = null,
            },
        );
        if (warmup_pass == null) {
            return .{ .status = .@"error", .status_message = "warmup commandEncoderBeginComputePass returned null" };
        }
        defer procs.wgpuComputePassEncoderRelease(warmup_pass);

        procs.wgpuComputePassEncoderSetPipeline(warmup_pass, pipeline);
        if (artifacts) |dispatch_artifacts| {
            for (dispatch_artifacts.pass_bind_groups, 0..) |bind_group, group| {
                if (bind_group) |actual_bind_group| {
                    procs.wgpuComputePassEncoderSetBindGroup(
                        warmup_pass,
                        @as(u32, @intCast(group)),
                        actual_bind_group,
                        0,
                        null,
                    );
                }
            }
        }
        var warmup_dispatch_index: u32 = 0;
        while (warmup_dispatch_index < warmup_dispatch_count) : (warmup_dispatch_index += 1) {
            if (dispatch_indirect_proc != null and dispatch_indirect_buffer != null) {
                dispatch_indirect_proc.?(warmup_pass, dispatch_indirect_buffer, 0);
            } else {
                procs.wgpuComputePassEncoderDispatchWorkgroups(warmup_pass, x, y, z);
            }
        }
        procs.wgpuComputePassEncoderEnd(warmup_pass);

        const warmup_command_buffer = procs.wgpuCommandEncoderFinish(warmup_encoder, &abi_descriptor.WGPUCommandBufferDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
        });
        if (warmup_command_buffer == null) {
            return .{ .status = .@"error", .status_message = "warmup commandEncoderFinish returned null" };
        }
        defer procs.wgpuCommandBufferRelease(warmup_command_buffer);

        var warmup_commands = [_]abi_base.WGPUCommandBuffer{warmup_command_buffer};
        _ = try self.submitCommandBuffers(warmup_commands[0..]);
    }

    const setup_end_ns = std.time.nanoTimestamp();

    const encode_start_ns = std.time.nanoTimestamp();
    const encoder = procs.wgpuDeviceCreateCommandEncoder(self.core.device.?, &abi_descriptor.WGPUCommandEncoderDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (encoder == null) {
        return .{ .status = .@"error", .status_message = "deviceCreateCommandEncoder returned null" };
    }
    defer procs.wgpuCommandEncoderRelease(encoder);

    const command_encoder_write_timestamp = procs.wgpuCommandEncoderWriteTimestamp;
    const use_compute_pass_timestamps = timestamps_active and compute_pass_write_timestamp != null and self.core.has_timestamp_inside_passes;
    const use_command_encoder_timestamps = timestamps_active and !use_compute_pass_timestamps and command_encoder_write_timestamp != null and self.core.has_timestamp_inside_passes;
    if (timestamps_active) {
        const mode = if (use_compute_pass_timestamps) "compute_pass" else if (use_command_encoder_timestamps) "command_encoder" else "pass_timestamp_writes";
        self.timestampLog(
            "timestamp_write_mode={s}\n",
            .{mode},
        );
    }
    var timestamp_writes = abi_descriptor.WGPUPassTimestampWrites{
        .nextInChain = null,
        .querySet = query_set,
        .beginningOfPassWriteIndex = 0,
        .endOfPassWriteIndex = 1,
    };

    if (use_command_encoder_timestamps) {
        command_encoder_write_timestamp.?(encoder, query_set, 0);
    }
    if (dispatch_indirect_proc != null and command_encoder_write_buffer != null and dispatch_indirect_buffer != null) {
        const dispatch_args = [3]u32{ x, y, z };
        const dispatch_args_bytes = std.mem.asBytes(&dispatch_args);
        command_encoder_write_buffer.?(encoder, dispatch_indirect_buffer, 0, dispatch_args_bytes.ptr, @as(u64, dispatch_args_bytes.len));
    }

    const pass = procs.wgpuCommandEncoderBeginComputePass(
        encoder,
        &abi_descriptor.WGPUComputePassDescriptor{
            .nextInChain = null,
            .label = loader.emptyStringView(),
            .timestampWrites = if (timestamps_active and !use_command_encoder_timestamps and !use_compute_pass_timestamps) &timestamp_writes else null,
        },
    );
    if (pass == null) {
        return .{ .status = .@"error", .status_message = "commandEncoderBeginComputePass returned null" };
    }
    defer procs.wgpuComputePassEncoderRelease(pass);

    procs.wgpuComputePassEncoderSetPipeline(pass, pipeline);
    if (artifacts) |dispatch_artifacts| {
        for (dispatch_artifacts.pass_bind_groups, 0..) |bind_group, group| {
            if (bind_group) |actual_bind_group| {
                procs.wgpuComputePassEncoderSetBindGroup(
                    pass,
                    @as(u32, @intCast(group)),
                    actual_bind_group,
                    0,
                    null,
                );
            }
        }
    }
    if (use_compute_pass_timestamps) {
        compute_pass_write_timestamp.?(pass, query_set, 0);
    }
    var dispatch_index: u32 = 0;
    while (dispatch_index < repeat_count) : (dispatch_index += 1) {
        if (dispatch_indirect_proc != null and dispatch_indirect_buffer != null) {
            dispatch_indirect_proc.?(pass, dispatch_indirect_buffer, 0);
        } else {
            procs.wgpuComputePassEncoderDispatchWorkgroups(pass, x, y, z);
        }
    }
    if (use_compute_pass_timestamps) {
        compute_pass_write_timestamp.?(pass, query_set, 1);
    }
    procs.wgpuComputePassEncoderEnd(pass);
    if (use_command_encoder_timestamps) {
        command_encoder_write_timestamp.?(encoder, query_set, 1);
    }

    if (timestamps_active) {
        procs.wgpuCommandEncoderResolveQuerySet(encoder, query_set, 0, 2, resolve_buffer, 0);
        procs.wgpuCommandEncoderCopyBufferToBuffer(encoder, resolve_buffer, 0, readback_buffer, 0, abi_base.TIMESTAMP_BUFFER_SIZE);
    }

    const command_buffer = procs.wgpuCommandEncoderFinish(encoder, &abi_descriptor.WGPUCommandBufferDescriptor{
        .nextInChain = null,
        .label = loader.emptyStringView(),
    });
    if (command_buffer == null) {
        return .{ .status = .@"error", .status_message = "commandEncoderFinish returned null" };
    }
    defer procs.wgpuCommandBufferRelease(command_buffer);
    const encode_end_ns = std.time.nanoTimestamp();

    var commands = [_]abi_base.WGPUCommandBuffer{command_buffer};
    const submit_wait_ns = try self.submitCommandBuffers(commands[0..]);

    const setup_ns = if (setup_end_ns > setup_start_ns)
        @as(u64, @intCast(setup_end_ns - setup_start_ns))
    else
        0;
    const encode_ns = if (encode_end_ns > encode_start_ns)
        @as(u64, @intCast(encode_end_ns - encode_start_ns))
    else
        0;
    var gpu_timestamp_ns: u64 = 0;
    var gpu_timestamp_valid = false;
    if (timestamps_active) {
        if (self.readTimestampBuffer(readback_buffer)) |timestamp_ns| {
            gpu_timestamp_ns = timestamp_ns;
        } else |err| {
            self.timestampLog("timestamp_readback_error={s}\n", .{@errorName(err)});
            if (timestamps_required) {
                return .{
                    .status = .@"error",
                    .status_message = timestampReadbackStatus(err),
                    .setup_ns = setup_ns,
                    .encode_ns = encode_ns,
                    .submit_wait_ns = submit_wait_ns,
                    .dispatch_count = repeat_count,
                    .gpu_timestamp_attempted = true,
                    .gpu_timestamp_valid = false,
                };
            }
            self.timestampLog("timestamp_fallback reason={s}\n", .{timestampReadbackStatus(err)});
            gpu_timestamp_ns = 0;
        }
        gpu_timestamp_valid = gpu_timestamp_ns > 0;
        self.timestampLog("timestamp_ns={}\n", .{gpu_timestamp_ns});
        if (!gpu_timestamp_valid) {
            if (!timestamps_required) {
                self.timestampLog("timestamp_fallback reason=zero_delta\n", .{});
                gpu_timestamp_ns = 0;
            } else {
                return .{
                    .status = .@"error",
                    .status_message = "gpu timestamp invalid (zero delta)",
                    .setup_ns = setup_ns,
                    .encode_ns = encode_ns,
                    .submit_wait_ns = submit_wait_ns,
                    .dispatch_count = repeat_count,
                    .gpu_timestamp_ns = gpu_timestamp_ns,
                    .gpu_timestamp_attempted = true,
                    .gpu_timestamp_valid = false,
                };
            }
        }
    }

    return .{
        .status = .ok,
        .status_message = switch (source.mode) {
            .builtin => "kernel source resolved via built-in kernel map",
            .file => "kernel source loaded and executed",
            .fallback => "kernel source loaded and executed",
        },
        .setup_ns = setup_ns,
        .encode_ns = encode_ns,
        .submit_wait_ns = submit_wait_ns,
        .dispatch_count = repeat_count,
        .gpu_timestamp_ns = gpu_timestamp_ns,
        .gpu_timestamp_attempted = timestamps_active,
        .gpu_timestamp_valid = gpu_timestamp_valid,
    };
}

pub fn validateKernelBindingsAgainstLimits(self: anytype, bindings: []const model_compute_types.KernelBinding) ?[]const u8 {
    const limits_ptr = self.effectiveLimits() orelse {
        return "kernel_dispatch requires negotiated WebGPU limits for binding validation";
    };
    const limits = limits_ptr.*;
    if (limits.maxBufferSize == 0) {
        return "kernel_dispatch received invalid maxBufferSize limit";
    }

    for (bindings) |binding| {
        if (binding.resource_kind != .buffer) continue;

        const range_size = bindingRangeSize(self, binding);
        if (range_size == 0) {
            return "kernel_dispatch buffer binding size must be non-zero";
        }
        if (range_size > limits.maxBufferSize) {
            return "kernel_dispatch binding range exceeds maxBufferSize";
        }
        if (binding.buffer_offset > limits.maxBufferSize - range_size) {
            return "kernel_dispatch binding offset+size exceeds maxBufferSize";
        }

        const binding_limit = bindingBufferLimit(binding, limits);
        if (binding_limit > 0 and range_size > binding_limit) {
            return switch (binding.buffer_type) {
                model_gpu_types.WGPUBufferBindingType_Uniform => "kernel_dispatch uniform binding exceeds maxUniformBufferBindingSize",
                else => "kernel_dispatch storage binding exceeds maxStorageBufferBindingSize",
            };
        }
    }
    return null;
}

pub fn bindingRangeSize(self: anytype, binding: model_compute_types.KernelBinding) u64 {
    if (binding.buffer_size == 0) return 0;
    if (binding.buffer_size == abi_base.WGPU_WHOLE_SIZE) {
        if (self.core.buffers.get(binding.resource_handle)) |record| {
            if (record.size <= binding.buffer_offset) return 0;
            return record.size - binding.buffer_offset;
        }
        return WHOLE_BUFFER_BINDING_MIN_BYTES;
    }
    return binding.buffer_size;
}

pub fn bindingBufferLimit(binding: model_compute_types.KernelBinding, limits: abi_descriptor.WGPULimits) u64 {
    return switch (binding.buffer_type) {
        model_gpu_types.WGPUBufferBindingType_Uniform => limits.maxUniformBufferBindingSize,
        model_gpu_types.WGPUBufferBindingType_Storage,
        model_gpu_types.WGPUBufferBindingType_ReadOnlyStorage,
        => limits.maxStorageBufferBindingSize,
        else => minPositiveLimit(limits.maxStorageBufferBindingSize, limits.maxUniformBufferBindingSize),
    };
}

pub fn minPositiveLimit(a: u64, b: u64) u64 {
    if (a == 0) return b;
    if (b == 0) return a;
    return @min(a, b);
}

pub fn timestampReadbackStatus(err: anyerror) []const u8 {
    return switch (err) {
        error.BufferMapTimeout => "gpu timestamp map timeout",
        error.BufferMapFailed => "gpu timestamp map failed",
        error.TimestampRangeInvalid => "gpu timestamp range invalid",
        error.WaitTimedOut => "gpu timestamp wait timed out",
        else => "gpu timestamp readback failed",
    };
}

pub fn resolveKernelSource(self: anytype, kernel_name: []const u8) !runtime_state.KernelSource {
    if (kernel_name.len == 0) return error.MissingKernelSource;
    if (openKernelFile(self, kernel_name)) |source| return source;
    if (self.core.kernel_root) |root| {
        if (openKernelFromRoot(self, kernel_name, root)) |source| return source;
    }
    return error.MissingKernelSource;
}

pub fn openKernelFile(self: anytype, path: []const u8) ?runtime_state.KernelSource {
    const maybe_file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound or err == error.NoSuchFileOrDirectory) {
            return null;
        }
        return null;
    };
    defer maybe_file.close();
    const text = maybe_file.readToEndAlloc(self.core.allocator, MAX_KERNEL_SOURCE_BYTES) catch return null;
    if (text.len == 0) {
        self.core.allocator.free(text);
        return null;
    }
    return .{ .source = text, .owned = true, .mode = .file };
}

pub fn openKernelFromRoot(self: anytype, kernel_name: []const u8, root: []const u8) ?runtime_state.KernelSource {
    if (kernel_name.len == 0) return null;
    const direct = std.fs.path.join(self.core.allocator, &[_][]const u8{ root, kernel_name }) catch return null;
    defer self.core.allocator.free(direct);
    if (openKernelFile(self, direct)) |source| return source;

    if (!std.mem.endsWith(u8, kernel_name, ".wgsl")) {
        const named = std.fmt.allocPrint(self.core.allocator, "{s}.wgsl", .{kernel_name}) catch return null;
        defer self.core.allocator.free(named);
        const candidate = std.fs.path.join(self.core.allocator, &[_][]const u8{ root, named }) catch return null;
        defer self.core.allocator.free(candidate);
        if (openKernelFile(self, candidate)) |source| return source;
    }
    return null;
}

pub fn hasValidTextureExtent(resource: model_resource_types.CopyTextureResource) bool {
    return resource.width > 0 and resource.height > 0 and resource.depth_or_array_layers > 0;
}

pub fn hasMatchingTextureExtent(src: model_resource_types.CopyTextureResource, dst: model_resource_types.CopyTextureResource) bool {
    return src.width == dst.width and
        src.height == dst.height and
        src.depth_or_array_layers == dst.depth_or_array_layers;
}

pub fn sourceContainsComputeStage(source: []const u8) bool {
    return std.mem.indexOf(u8, source, "@compute") != null;
}
