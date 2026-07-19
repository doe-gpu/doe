const std = @import("std");
const synthetic_assets = @import("synthetic_assets.zig");
const dawn_plan_types = @import("dawn_plan_types.zig");
const support = @import("webgpu_plan_executor_support.zig");

const Allocator = std.mem.Allocator;
const c = support.c;

const DEFAULT_SEMANTIC_STAGE = "webgpu_plan";

pub const LiveExecution = struct {
    results: []support.StepResult,
    identity: support.BackendIdentity,
    host_executor_init_total_ns: u64,
    execute_wall_ns: u64,
};

const Executor = struct {
    allocator: Allocator,
    lib: std.DynLib,
    procs: support.WebGpuProcs,
    identity: support.BackendIdentity,
    instance: c.WGPUInstance,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    buffers: std.AutoHashMap(u64, support.BufferRecord),
    pipeline_cache: std.AutoHashMap(u64, support.CachedPipeline),
    buffer_specs: std.AutoHashMap(u64, support.BufferSpec),

    fn init(allocator: Allocator, buffer_specs: *const std.AutoHashMap(u64, support.BufferSpec), backend_id_override: ?[]const u8) !Executor {
        var lib = try support.openDirectWebGpuLibrary();
        errdefer lib.close();
        const procs = try support.loadWebGpuProcs(lib);

        const identity = if (backend_id_override) |override| blk: {
            if (std.mem.eql(u8, override, support.WEBKIT_BACKEND_ID)) {
                break :blk support.WEBKIT_IDENTITY;
            }
            break :blk support.DAWN_IDENTITY;
        } else support.probeBackendIdentity(lib);

        const instance_desc = c.WGPUInstanceDescriptor{ .nextInChain = null };
        const instance = procs.create_instance(&instance_desc) orelse return error.InstanceCreateFailed;

        var self = Executor{
            .allocator = allocator,
            .lib = lib,
            .procs = procs,
            .identity = identity,
            .instance = instance,
            .adapter = null,
            .device = null,
            .queue = null,
            .buffers = std.AutoHashMap(u64, support.BufferRecord).init(allocator),
            .pipeline_cache = std.AutoHashMap(u64, support.CachedPipeline).init(allocator),
            .buffer_specs = std.AutoHashMap(u64, support.BufferSpec).init(allocator),
        };
        errdefer self.deinit();

        var spec_iter = buffer_specs.iterator();
        while (spec_iter.next()) |entry| {
            try self.buffer_specs.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        try self.requestAdapter();
        try self.requestDevice();
        self.queue = self.procs.device_get_queue(self.device) orelse return error.QueueUnavailable;
        return self;
    }

    fn deinit(self: *Executor) void {
        var cache_iter = self.pipeline_cache.iterator();
        while (cache_iter.next()) |entry| {
            const cached = entry.value_ptr.*;
            for (cached.group_layouts) |layout| self.procs.bind_group_layout_release(layout);
            self.allocator.free(cached.group_layouts);
            self.procs.compute_pipeline_release(cached.pipeline);
            self.procs.pipeline_layout_release(cached.pipeline_layout);
            self.procs.shader_module_release(cached.shader_module);
        }
        self.pipeline_cache.deinit();

        var buffer_iter = self.buffers.iterator();
        while (buffer_iter.next()) |entry| {
            self.procs.buffer_release(entry.value_ptr.buffer);
        }
        self.buffers.deinit();
        self.buffer_specs.deinit();

        if (self.queue != null) self.procs.queue_release(self.queue);
        if (self.device != null) {
            self.procs.device_destroy(self.device);
            self.procs.device_release(self.device);
        }
        if (self.adapter != null) self.procs.adapter_release(self.adapter);
        if (self.instance != null) self.procs.instance_release(self.instance);
        self.lib.close();
    }

    fn requestAdapter(self: *Executor) !void {
        const backend_candidates = [_]c.WGPUBackendType{
            c.WGPUBackendType_Metal,
            c.WGPUBackendType_Undefined,
        };
        for (backend_candidates) |backend_type| {
            if (self.tryRequestAdapter(backend_type)) |adapter| {
                self.adapter = adapter;
                return;
            } else |_| {}
        }
        return error.AdapterRequestFailed;
    }

    fn tryRequestAdapter(self: *Executor, backend_type: c.WGPUBackendType) !c.WGPUAdapter {
        var state = support.AdapterState{};
        const callback = c.WGPURequestAdapterCallbackInfo{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = support.requestAdapterCallback,
            .userdata1 = &state,
            .userdata2 = null,
        };
        const options = c.WGPURequestAdapterOptions{
            .nextInChain = null,
            .featureLevel = c.WGPUFeatureLevel_Undefined,
            .powerPreference = c.WGPUPowerPreference_HighPerformance,
            .forceFallbackAdapter = c.WGPU_FALSE,
            .backendType = backend_type,
            .compatibleSurface = null,
        };
        const future = self.procs.instance_request_adapter(self.instance, &options, callback);
        if (future.id == 0) return error.AdapterRequestFailed;
        try support.waitForFlag(self.instance, self.procs.instance_process_events, &state.done, support.ASYNC_TIMEOUT_NS);
        if (state.status != c.WGPURequestAdapterStatus_Success or state.adapter == null) return error.AdapterRequestFailed;
        return state.adapter;
    }

    fn requestDevice(self: *Executor) !void {
        var state = support.DeviceState{};
        const callback = c.WGPURequestDeviceCallbackInfo{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = support.requestDeviceCallback,
            .userdata1 = &state,
            .userdata2 = null,
        };
        var required_features = [_]c.WGPUFeatureName{undefined} ** 1;
        var feature_count: usize = 0;
        if (self.procs.adapter_has_feature(self.adapter, c.WGPUFeatureName_ShaderF16) != c.WGPU_FALSE) {
            required_features[feature_count] = c.WGPUFeatureName_ShaderF16;
            feature_count += 1;
        }
        const desc = c.WGPUDeviceDescriptor{
            .nextInChain = null,
            .requiredFeatureCount = feature_count,
            .requiredFeatures = if (feature_count > 0) required_features[0..].ptr else null,
        };
        const future = self.procs.adapter_request_device(self.adapter, &desc, callback);
        if (future.id == 0) return error.DeviceRequestFailed;
        try support.waitForFlag(self.instance, self.procs.instance_process_events, &state.done, support.ASYNC_TIMEOUT_NS);
        if (state.status != c.WGPURequestDeviceStatus_Success or state.device == null) return error.DeviceRequestFailed;
        self.device = state.device;
    }

    fn specForHandle(self: *Executor, handle: u64) !support.BufferSpec {
        return self.buffer_specs.get(handle) orelse error.InvalidPlan;
    }

    fn ensureBuffer(self: *Executor, handle: u64) !c.WGPUBuffer {
        const spec = try self.specForHandle(handle);
        if (spec.size == 0) return error.InvalidPlan;
        if (self.buffers.getPtr(handle)) |record| {
            if (record.size < spec.size or (record.usage & spec.usage) != spec.usage) return error.InvalidPlan;
            return record.buffer;
        }

        const desc = c.WGPUBufferDescriptor{
            .nextInChain = null,
            .label = support.emptyStringView(),
            .usage = spec.usage,
            .size = spec.size,
            .mappedAtCreation = c.WGPU_FALSE,
        };
        const buffer = self.procs.device_create_buffer(self.device, &desc) orelse return error.BufferCreateFailed;
        errdefer self.procs.buffer_release(buffer);
        try self.buffers.put(handle, .{ .buffer = buffer, .size = spec.size, .usage = spec.usage });
        return buffer;
    }

    fn getOrCreatePipeline(
        self: *Executor,
        source: []const u8,
        entry_point: []const u8,
        bindings: []const dawn_plan_types.KernelBinding,
    ) !support.CachedPipeline {
        const key = support.pipelineKey(source, entry_point, bindings);
        if (self.pipeline_cache.get(key)) |cached| return cached;

        const shader_module = try self.createShaderModule(source);
        errdefer self.procs.shader_module_release(shader_module);

        const bind_group_layout = try self.createBindGroupLayout(bindings);
        errdefer self.procs.bind_group_layout_release(bind_group_layout);

        const group_layouts = try self.allocator.alloc(c.WGPUBindGroupLayout, 1);
        errdefer self.allocator.free(group_layouts);
        group_layouts[0] = bind_group_layout;

        const pipeline_layout = try self.createPipelineLayout(group_layouts);
        errdefer self.procs.pipeline_layout_release(pipeline_layout);

        const pipeline = try self.createComputePipeline(shader_module, pipeline_layout, entry_point);
        errdefer self.procs.compute_pipeline_release(pipeline);

        const cached = support.CachedPipeline{
            .shader_module = shader_module,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .group_layouts = group_layouts,
        };
        try self.pipeline_cache.put(key, cached);
        return cached;
    }

    fn createShaderModule(self: *Executor, source: []const u8) !c.WGPUShaderModule {
        const wgsl = c.WGPUShaderSourceWGSL{
            .chain = .{ .next = null, .sType = c.WGPUSType_ShaderSourceWGSL },
            .code = .{ .data = source.ptr, .length = source.len },
        };
        const desc = c.WGPUShaderModuleDescriptor{
            .nextInChain = @constCast(&wgsl.chain),
            .label = support.emptyStringView(),
        };
        return self.procs.device_create_shader_module(self.device, &desc) orelse error.ShaderModuleCreateFailed;
    }

    fn createBindGroupLayout(self: *Executor, bindings: []const dawn_plan_types.KernelBinding) !c.WGPUBindGroupLayout {
        const entries = try self.allocator.alloc(c.WGPUBindGroupLayoutEntry, bindings.len);
        defer self.allocator.free(entries);
        for (bindings, 0..) |binding, idx| {
            var entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
            entry.binding = binding.binding;
            entry.visibility = c.WGPUShaderStage_Compute;
            entry.buffer.nextInChain = null;
            entry.buffer.type = support.bufferBindingTypeFor(binding.buffer_type);
            entry.buffer.hasDynamicOffset = c.WGPU_FALSE;
            entry.buffer.minBindingSize = binding.buffer_size;
            entries[idx] = entry;
        }
        const desc = c.WGPUBindGroupLayoutDescriptor{
            .nextInChain = null,
            .label = support.emptyStringView(),
            .entryCount = entries.len,
            .entries = entries.ptr,
        };
        return self.procs.device_create_bind_group_layout(self.device, &desc) orelse error.BindGroupLayoutCreateFailed;
    }

    fn createPipelineLayout(self: *Executor, layouts: []const c.WGPUBindGroupLayout) !c.WGPUPipelineLayout {
        const desc = c.WGPUPipelineLayoutDescriptor{
            .nextInChain = null,
            .label = support.emptyStringView(),
            .bindGroupLayoutCount = layouts.len,
            .bindGroupLayouts = layouts.ptr,
            .immediateSize = 0,
        };
        return self.procs.device_create_pipeline_layout(self.device, &desc) orelse error.PipelineLayoutCreateFailed;
    }

    fn createComputePipeline(self: *Executor, shader_module: c.WGPUShaderModule, pipeline_layout: c.WGPUPipelineLayout, entry_point: []const u8) !c.WGPUComputePipeline {
        const desc = c.WGPUComputePipelineDescriptor{
            .nextInChain = null,
            .label = support.emptyStringView(),
            .layout = pipeline_layout,
            .compute = .{
                .nextInChain = null,
                .module = shader_module,
                .entryPoint = .{ .data = entry_point.ptr, .length = entry_point.len },
                .constantCount = 0,
                .constants = null,
            },
        };
        return self.procs.device_create_compute_pipeline(self.device, &desc) orelse error.ComputePipelineCreateFailed;
    }

    fn executeBufferWrite(self: *Executor, seq: u64, plan_hash: []const u8, command: dawn_plan_types.BufferWriteCommand) !support.StepResult {
        const start_ns = support.nowNs();
        const buffer = try self.ensureBuffer(command.handle);
        const spec = try self.specForHandle(command.handle);
        const bytes = std.mem.sliceAsBytes(command.data);
        if (command.offset + bytes.len > spec.size) return error.InvalidPlan;
        const setup_ns = support.elapsedSince(start_ns);

        const encode_start = support.nowNs();
        self.procs.queue_write_buffer(self.queue, buffer, command.offset, bytes.ptr, bytes.len);
        const encode_ns = support.elapsedSince(encode_start);

        return .{
            .seq = seq,
            .command_kind = "buffer_write",
            .kernel = null,
            .semantic_stage = DEFAULT_SEMANTIC_STAGE,
            .semantic_phase = "buffer_write",
            .status = "ok",
            .status_code = "ok",
            .status_message = "queue.writeBuffer",
            .timestamp_mono_ns = support.nowNs(),
            .duration_ns = setup_ns + encode_ns,
            .setup_ns = setup_ns,
            .encode_ns = encode_ns,
            .submit_wait_ns = 0,
            .dispatch_count = 0,
            .submit_count = 0,
            .execution_backend = self.identity.execution_backend,
            .backend_id = self.identity.backend_id,
            .backend_lane = self.identity.backend_lane,
            .plan_hash = plan_hash,
        };
    }

    fn executeBufferLoad(self: *Executor, seq: u64, plan_hash: []const u8, command: dawn_plan_types.BufferLoadCommand) !support.StepResult {
        const start_ns = support.nowNs();
        const buffer = try self.ensureBuffer(command.handle);
        const spec = try self.specForHandle(command.handle);
        const bytes = try synthetic_assets.readAssetBytes(
            self.allocator,
            command.cache_namespace,
            command.cache_key,
            command.byte_length,
        );
        defer self.allocator.free(bytes);
        if (command.offset + bytes.len > spec.size) return error.InvalidPlan;
        const setup_ns = support.elapsedSince(start_ns);

        const encode_start = support.nowNs();
        self.procs.queue_write_buffer(self.queue, buffer, command.offset, bytes.ptr, bytes.len);
        const encode_ns = support.elapsedSince(encode_start);

        return .{
            .seq = seq,
            .command_kind = "buffer_load",
            .kernel = null,
            .semantic_stage = DEFAULT_SEMANTIC_STAGE,
            .semantic_phase = "buffer_load",
            .status = "ok",
            .status_code = "ok",
            .status_message = "synthetic asset load via queue.writeBuffer",
            .timestamp_mono_ns = support.nowNs(),
            .duration_ns = setup_ns + encode_ns,
            .setup_ns = setup_ns,
            .encode_ns = encode_ns,
            .submit_wait_ns = 0,
            .dispatch_count = 0,
            .submit_count = 0,
            .execution_backend = self.identity.execution_backend,
            .backend_id = self.identity.backend_id,
            .backend_lane = self.identity.backend_lane,
            .plan_hash = plan_hash,
        };
    }

    fn executeKernelDispatch(
        self: *Executor,
        seq: u64,
        plan_hash: []const u8,
        kernel_root: []const u8,
        command: dawn_plan_types.KernelDispatchCommand,
    ) !support.StepResult {
        const start_ns = support.nowNs();
        const kernel_source = try support.loadKernelSource(self.allocator, kernel_root, command.kernel);
        defer self.allocator.free(kernel_source);

        var buffered = try self.allocator.alloc(c.WGPUBuffer, command.bindings.len);
        defer self.allocator.free(buffered);
        for (command.bindings, 0..) |binding, idx| {
            if (binding.group != 0) return error.UnsupportedCommand;
            const spec = try self.specForHandle(binding.resource_handle);
            if (binding.buffer_size > spec.size) return error.InvalidPlan;
            buffered[idx] = try self.ensureBuffer(binding.resource_handle);
        }
        const cached = try self.getOrCreatePipeline(kernel_source, command.entry_point, command.bindings);
        const setup_ns = support.elapsedSince(start_ns);

        const encode_start = support.nowNs();
        var bind_entries = try self.allocator.alloc(c.WGPUBindGroupEntry, command.bindings.len);
        defer self.allocator.free(bind_entries);
        for (command.bindings, 0..) |binding, idx| {
            const spec = try self.specForHandle(binding.resource_handle);
            var entry = std.mem.zeroes(c.WGPUBindGroupEntry);
            entry.binding = binding.binding;
            entry.buffer = buffered[idx];
            entry.offset = 0;
            entry.size = if (binding.buffer_size > 0) binding.buffer_size else spec.size;
            bind_entries[idx] = entry;
        }

        const bind_group_desc = c.WGPUBindGroupDescriptor{
            .nextInChain = null,
            .label = support.emptyStringView(),
            .layout = cached.group_layouts[0],
            .entryCount = bind_entries.len,
            .entries = bind_entries.ptr,
        };
        const bind_group = self.procs.device_create_bind_group(self.device, &bind_group_desc) orelse return error.BindGroupCreateFailed;
        defer self.procs.bind_group_release(bind_group);

        const encoder_desc = c.WGPUCommandEncoderDescriptor{ .nextInChain = null, .label = support.emptyStringView() };
        const encoder = self.procs.device_create_command_encoder(self.device, &encoder_desc) orelse return error.CommandEncoderCreateFailed;
        defer self.procs.command_encoder_release(encoder);

        const pass_desc = c.WGPUComputePassDescriptor{ .nextInChain = null, .label = support.emptyStringView(), .timestampWrites = null };
        const pass = self.procs.command_encoder_begin_compute_pass(encoder, &pass_desc) orelse return error.ComputePassCreateFailed;
        defer self.procs.compute_pass_encoder_release(pass);

        self.procs.compute_pass_encoder_set_pipeline(pass, cached.pipeline);
        self.procs.compute_pass_encoder_set_bind_group(pass, 0, bind_group, 0, null);
        self.procs.compute_pass_encoder_dispatch_workgroups(pass, command.x, command.y, command.z);
        self.procs.compute_pass_encoder_end(pass);

        const command_buffer_desc = c.WGPUCommandBufferDescriptor{ .nextInChain = null, .label = support.emptyStringView() };
        const command_buffer = self.procs.command_encoder_finish(encoder, &command_buffer_desc) orelse return error.CommandBufferFinishFailed;
        defer self.procs.command_buffer_release(command_buffer);
        const encode_ns = support.elapsedSince(encode_start);

        const submit_start = support.nowNs();
        var command_buffers = [_]c.WGPUCommandBuffer{command_buffer};
        self.procs.queue_submit(self.queue, command_buffers.len, &command_buffers);
        try self.waitForQueue();
        const submit_wait_ns = support.elapsedSince(submit_start);

        return .{
            .seq = seq,
            .command_kind = "kernel_dispatch",
            .kernel = command.kernel,
            .semantic_stage = DEFAULT_SEMANTIC_STAGE,
            .semantic_phase = "kernel_dispatch",
            .status = "ok",
            .status_code = "ok",
            .status_message = "compute dispatch completed",
            .timestamp_mono_ns = support.nowNs(),
            .duration_ns = setup_ns + encode_ns + submit_wait_ns,
            .setup_ns = setup_ns,
            .encode_ns = encode_ns,
            .submit_wait_ns = submit_wait_ns,
            .dispatch_count = 1,
            .submit_count = 1,
            .execution_backend = self.identity.execution_backend,
            .backend_id = self.identity.backend_id,
            .backend_lane = self.identity.backend_lane,
            .plan_hash = plan_hash,
        };
    }

    fn waitForQueue(self: *Executor) !void {
        var state = support.WaitState{};
        const callback = c.WGPUQueueWorkDoneCallbackInfo{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowProcessEvents,
            .callback = support.queueDoneCallback,
            .userdata1 = &state,
            .userdata2 = null,
        };
        const future = self.procs.queue_on_submitted_work_done(self.queue, callback);
        if (future.id == 0) return error.QueueWaitFailed;
        try support.waitForFlag(self.instance, self.procs.instance_process_events, &state.done, support.ASYNC_TIMEOUT_NS);
        if (state.status != c.WGPUQueueWorkDoneStatus_Success) return error.QueueWaitFailed;
    }

    fn execute(self: *Executor, plan: dawn_plan_types.Plan, plan_hash: []const u8, kernel_root: []const u8) ![]support.StepResult {
        const results = try self.allocator.alloc(support.StepResult, plan.commands.len);
        errdefer self.allocator.free(results);
        for (plan.commands, 0..) |command, idx| {
            const seq = @as(u64, idx);
            results[idx] = switch (command) {
                .buffer_write => |bw| try self.executeBufferWrite(seq, plan_hash, bw),
                .buffer_load => |bl| try self.executeBufferLoad(seq, plan_hash, bl),
                .kernel_dispatch => |kd| try self.executeKernelDispatch(seq, plan_hash, kernel_root, kd),
            };
        }
        return results;
    }
};

pub fn executeLivePlan(
    allocator: Allocator,
    buffer_specs: *const std.AutoHashMap(u64, support.BufferSpec),
    backend_id_override: ?[]const u8,
    plan: dawn_plan_types.Plan,
    kernel_root: []const u8,
) !LiveExecution {
    const executor_init_start_ns = support.nowNs();
    var executor = try Executor.init(allocator, buffer_specs, backend_id_override);
    const host_executor_init_total_ns = support.elapsedSince(executor_init_start_ns);
    defer executor.deinit();

    const execute_start_ns = support.nowNs();
    const results = try executor.execute(plan, plan.plan_sha256, kernel_root);
    const execute_wall_ns = support.elapsedSince(execute_start_ns);

    return .{
        .results = results,
        .identity = executor.identity,
        .host_executor_init_total_ns = host_executor_init_total_ns,
        .execute_wall_ns = execute_wall_ns,
    };
}
