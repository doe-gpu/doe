const std = @import("std");
const dawn_plan_types = @import("dawn_plan_types.zig");

pub const c = @cImport({
    @cInclude("webgpu.h");
});

pub const DEFAULT_MODULE_NAME = "webgpu-plan-executor";
pub const DEFAULT_BACKEND_ID = "dawn_direct_metal";
pub const DEFAULT_PROFILE_VENDOR = "apple";
pub const DEFAULT_PROFILE_API = "metal";
pub const DEFAULT_PROFILE_DRIVER = "libwebgpu_dawn.dylib";
pub const DEFAULT_KERNEL_ROOT = "bench/inference-pipeline/kernels";
pub const HASH_SEED: u64 = 0x9e3779b97f4a7c15;
pub const ASYNC_TIMEOUT_NS: u64 = 5_000_000_000;
pub const ZERO_INIT_CHUNK_BYTES: usize = 64 * 1024;

pub const WEBKIT_BACKEND_ID = "webkit_direct_metal";
pub const WEBKIT_BACKEND_LANE = "metal_webkit_release";
pub const WEBKIT_PROFILE_DRIVER = "libwebgpu_webkit_cshim.dylib";

/// Identity strings for the loaded WebGPU backend.
/// Resolved by probeBackendIdentity() after dlopen.
pub const BackendIdentity = struct {
    backend_id: []const u8,
    backend_lane: []const u8,
    execution_backend: []const u8,
    profile_driver: []const u8,
};

pub const DAWN_IDENTITY = BackendIdentity{
    .backend_id = DEFAULT_BACKEND_ID,
    .backend_lane = "metal_dawn_release",
    .execution_backend = DEFAULT_BACKEND_ID,
    .profile_driver = DEFAULT_PROFILE_DRIVER,
};

pub const WEBKIT_IDENTITY = BackendIdentity{
    .backend_id = WEBKIT_BACKEND_ID,
    .backend_lane = WEBKIT_BACKEND_LANE,
    .execution_backend = WEBKIT_BACKEND_ID,
    .profile_driver = WEBKIT_PROFILE_DRIVER,
};

/// Probe the loaded library for the WebKit shim identity symbol.
/// If doe_shim_get_backend_identity resolves, the library is the WebKit shim.
/// Otherwise it's Dawn (or another implementation without the probe symbol).
pub fn probeBackendIdentity(lib: std.DynLib) BackendIdentity {
    const FnGetIdentity = *const fn () callconv(.c) [*:0]const u8;
    var mutable = lib;
    if (mutable.lookup(FnGetIdentity, "doe_shim_get_backend_identity")) |_| {
        return WEBKIT_IDENTITY;
    }
    return DAWN_IDENTITY;
}

pub const FnCreateInstance = *const fn (?*const c.WGPUInstanceDescriptor) callconv(.c) c.WGPUInstance;
pub const FnInstanceRequestAdapter = *const fn (c.WGPUInstance, ?*const c.WGPURequestAdapterOptions, c.WGPURequestAdapterCallbackInfo) callconv(.c) c.WGPUFuture;
pub const FnInstanceProcessEvents = *const fn (c.WGPUInstance) callconv(.c) void;
pub const FnAdapterRequestDevice = *const fn (c.WGPUAdapter, ?*const c.WGPUDeviceDescriptor, c.WGPURequestDeviceCallbackInfo) callconv(.c) c.WGPUFuture;
pub const FnAdapterHasFeature = *const fn (c.WGPUAdapter, c.WGPUFeatureName) callconv(.c) c.WGPUBool;
pub const FnAdapterRelease = *const fn (c.WGPUAdapter) callconv(.c) void;
pub const FnDeviceGetQueue = *const fn (c.WGPUDevice) callconv(.c) c.WGPUQueue;
pub const FnDeviceDestroy = *const fn (c.WGPUDevice) callconv(.c) void;
pub const FnDeviceRelease = *const fn (c.WGPUDevice) callconv(.c) void;
pub const FnQueueRelease = *const fn (c.WGPUQueue) callconv(.c) void;
pub const FnQueueSubmit = *const fn (c.WGPUQueue, usize, [*]const c.WGPUCommandBuffer) callconv(.c) void;
pub const FnQueueWriteBuffer = *const fn (c.WGPUQueue, c.WGPUBuffer, u64, ?*const anyopaque, usize) callconv(.c) void;
pub const FnQueueOnSubmittedWorkDone = *const fn (c.WGPUQueue, c.WGPUQueueWorkDoneCallbackInfo) callconv(.c) c.WGPUFuture;
pub const FnBufferRelease = *const fn (c.WGPUBuffer) callconv(.c) void;
pub const FnDeviceCreateBuffer = *const fn (c.WGPUDevice, *const c.WGPUBufferDescriptor) callconv(.c) c.WGPUBuffer;
pub const FnDeviceCreateShaderModule = *const fn (c.WGPUDevice, *const c.WGPUShaderModuleDescriptor) callconv(.c) c.WGPUShaderModule;
pub const FnShaderModuleRelease = *const fn (c.WGPUShaderModule) callconv(.c) void;
pub const FnDeviceCreateBindGroupLayout = *const fn (c.WGPUDevice, *const c.WGPUBindGroupLayoutDescriptor) callconv(.c) c.WGPUBindGroupLayout;
pub const FnBindGroupLayoutRelease = *const fn (c.WGPUBindGroupLayout) callconv(.c) void;
pub const FnDeviceCreateBindGroup = *const fn (c.WGPUDevice, *const c.WGPUBindGroupDescriptor) callconv(.c) c.WGPUBindGroup;
pub const FnBindGroupRelease = *const fn (c.WGPUBindGroup) callconv(.c) void;
pub const FnDeviceCreatePipelineLayout = *const fn (c.WGPUDevice, *const c.WGPUPipelineLayoutDescriptor) callconv(.c) c.WGPUPipelineLayout;
pub const FnPipelineLayoutRelease = *const fn (c.WGPUPipelineLayout) callconv(.c) void;
pub const FnDeviceCreateComputePipeline = *const fn (c.WGPUDevice, *const c.WGPUComputePipelineDescriptor) callconv(.c) c.WGPUComputePipeline;
pub const FnComputePipelineRelease = *const fn (c.WGPUComputePipeline) callconv(.c) void;
pub const FnDeviceCreateCommandEncoder = *const fn (c.WGPUDevice, ?*const c.WGPUCommandEncoderDescriptor) callconv(.c) c.WGPUCommandEncoder;
pub const FnCommandEncoderRelease = *const fn (c.WGPUCommandEncoder) callconv(.c) void;
pub const FnCommandEncoderBeginComputePass = *const fn (c.WGPUCommandEncoder, ?*const c.WGPUComputePassDescriptor) callconv(.c) c.WGPUComputePassEncoder;
pub const FnComputePassEncoderSetPipeline = *const fn (c.WGPUComputePassEncoder, c.WGPUComputePipeline) callconv(.c) void;
pub const FnComputePassEncoderSetBindGroup = *const fn (c.WGPUComputePassEncoder, u32, c.WGPUBindGroup, usize, ?[*]const u32) callconv(.c) void;
pub const FnComputePassEncoderDispatchWorkgroups = *const fn (c.WGPUComputePassEncoder, u32, u32, u32) callconv(.c) void;
pub const FnComputePassEncoderEnd = *const fn (c.WGPUComputePassEncoder) callconv(.c) void;
pub const FnComputePassEncoderRelease = *const fn (c.WGPUComputePassEncoder) callconv(.c) void;
pub const FnCommandEncoderFinish = *const fn (c.WGPUCommandEncoder, ?*const c.WGPUCommandBufferDescriptor) callconv(.c) c.WGPUCommandBuffer;
pub const FnCommandBufferRelease = *const fn (c.WGPUCommandBuffer) callconv(.c) void;
pub const FnInstanceRelease = *const fn (c.WGPUInstance) callconv(.c) void;

pub const StepResult = struct {
    seq: u64,
    command_kind: []const u8,
    kernel: ?[]const u8 = null,
    semantic_stage: []const u8,
    semantic_phase: []const u8,
    status: []const u8,
    status_code: []const u8,
    status_message: []const u8,
    timestamp_mono_ns: u64,
    duration_ns: u64,
    setup_ns: u64,
    encode_ns: u64,
    submit_wait_ns: u64,
    dispatch_count: u32,
    submit_count: u32,
    execution_backend: []const u8,
    backend_id: []const u8,
    backend_lane: []const u8,
    plan_hash: []const u8,
};

pub const RunSummary = struct {
    row_count: u64 = 0,
    success_count: u64 = 0,
    error_count: u64 = 0,
    skipped_count: u64 = 0,
    unsupported_count: u64 = 0,
    dispatch_count: u64 = 0,
    submit_count: u64 = 0,
    total_ns: u64 = 0,
    setup_total_ns: u64 = 0,
    encode_total_ns: u64 = 0,
    submit_wait_total_ns: u64 = 0,
    host_input_read_total_ns: u64 = 0,
    host_input_parse_total_ns: u64 = 0,
    host_workload_prepare_total_ns: u64 = 0,
    host_executor_init_total_ns: u64 = 0,
    host_upload_prewarm_total_ns: u64 = 0,
    host_kernel_prewarm_total_ns: u64 = 0,
    host_command_orchestration_total_ns: u64 = 0,
    host_artifact_finalize_total_ns: u64 = 0,
    seq_max: u64 = 0,
    final_hash: u64 = HASH_SEED,
    previous_hash: u64 = HASH_SEED,
    process_wall_ns: u64 = 0,
};

pub const BufferSpec = struct {
    size: u64,
    usage: c.WGPUBufferUsage,
};

pub const BufferRecord = struct {
    buffer: c.WGPUBuffer,
    size: u64,
    usage: c.WGPUBufferUsage,
};

pub const CachedPipeline = struct {
    shader_module: c.WGPUShaderModule,
    pipeline_layout: c.WGPUPipelineLayout,
    pipeline: c.WGPUComputePipeline,
    group_layouts: []c.WGPUBindGroupLayout,
};

pub const WaitState = struct {
    done: bool = false,
    status: c.WGPUQueueWorkDoneStatus = c.WGPUQueueWorkDoneStatus_Error,
};

pub const AdapterState = struct {
    done: bool = false,
    status: c.WGPURequestAdapterStatus = c.WGPURequestAdapterStatus_Error,
    adapter: c.WGPUAdapter = null,
};

pub const DeviceState = struct {
    done: bool = false,
    status: c.WGPURequestDeviceStatus = c.WGPURequestDeviceStatus_Error,
    device: c.WGPUDevice = null,
};

pub const WebGpuProcs = struct {
    create_instance: FnCreateInstance,
    instance_request_adapter: FnInstanceRequestAdapter,
    instance_process_events: FnInstanceProcessEvents,
    adapter_request_device: FnAdapterRequestDevice,
    adapter_has_feature: FnAdapterHasFeature,
    adapter_release: FnAdapterRelease,
    device_get_queue: FnDeviceGetQueue,
    device_destroy: FnDeviceDestroy,
    device_release: FnDeviceRelease,
    queue_release: FnQueueRelease,
    queue_submit: FnQueueSubmit,
    queue_write_buffer: FnQueueWriteBuffer,
    queue_on_submitted_work_done: FnQueueOnSubmittedWorkDone,
    buffer_release: FnBufferRelease,
    device_create_buffer: FnDeviceCreateBuffer,
    device_create_shader_module: FnDeviceCreateShaderModule,
    shader_module_release: FnShaderModuleRelease,
    device_create_bind_group_layout: FnDeviceCreateBindGroupLayout,
    bind_group_layout_release: FnBindGroupLayoutRelease,
    device_create_bind_group: FnDeviceCreateBindGroup,
    bind_group_release: FnBindGroupRelease,
    device_create_pipeline_layout: FnDeviceCreatePipelineLayout,
    pipeline_layout_release: FnPipelineLayoutRelease,
    device_create_compute_pipeline: FnDeviceCreateComputePipeline,
    compute_pipeline_release: FnComputePipelineRelease,
    device_create_command_encoder: FnDeviceCreateCommandEncoder,
    command_encoder_release: FnCommandEncoderRelease,
    command_encoder_begin_compute_pass: FnCommandEncoderBeginComputePass,
    compute_pass_encoder_set_pipeline: FnComputePassEncoderSetPipeline,
    compute_pass_encoder_set_bind_group: FnComputePassEncoderSetBindGroup,
    compute_pass_encoder_dispatch_workgroups: FnComputePassEncoderDispatchWorkgroups,
    compute_pass_encoder_end: FnComputePassEncoderEnd,
    compute_pass_encoder_release: FnComputePassEncoderRelease,
    command_encoder_finish: FnCommandEncoderFinish,
    command_buffer_release: FnCommandBufferRelease,
    instance_release: FnInstanceRelease,
};

pub fn openDirectWebGpuLibrary() !std.DynLib {
    const cwd_candidates = [_][]const u8{
        "bench/vendor/dawn/out/Release/libwebgpu_dawn.dylib",
        "../../bench/vendor/dawn/out/Release/libwebgpu_dawn.dylib",
        "libwebgpu_dawn.dylib",
    };
    if (openCandidates(cwd_candidates[0..])) |lib| return lib;

    const exe_path = std.fs.selfExePathAlloc(std.heap.page_allocator) catch null;
    if (exe_path) |path| {
        defer std.heap.page_allocator.free(path);
        if (std.fs.path.dirname(path)) |dir| {
            const exe_candidates = [_][]const u8{
                "../../../../bench/vendor/dawn/out/Release/libwebgpu_dawn.dylib",
                "../../../bench/vendor/dawn/out/Release/libwebgpu_dawn.dylib",
                "../../bench/vendor/dawn/out/Release/libwebgpu_dawn.dylib",
            };
            if (openCandidatesFromDir(dir, exe_candidates[0..])) |lib| return lib;
        }
    }

    return error.LibraryOpenFailed;
}

fn openCandidates(candidates: []const []const u8) ?std.DynLib {
    return openCandidatesFromDir("", candidates);
}

fn openCandidatesFromDir(dir: []const u8, candidates: []const []const u8) ?std.DynLib {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (candidates) |candidate| {
        const path = if (dir.len == 0) candidate else std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, candidate }) catch continue;
        const lib = std.DynLib.open(path) catch continue;
        return lib;
    }
    return null;
}

pub fn loadWebGpuProcs(lib: std.DynLib) !WebGpuProcs {
    return .{
        .create_instance = try loadProc(lib, FnCreateInstance, "wgpuCreateInstance"),
        .instance_request_adapter = try loadProc(lib, FnInstanceRequestAdapter, "wgpuInstanceRequestAdapter"),
        .instance_process_events = try loadProc(lib, FnInstanceProcessEvents, "wgpuInstanceProcessEvents"),
        .adapter_request_device = try loadProc(lib, FnAdapterRequestDevice, "wgpuAdapterRequestDevice"),
        .adapter_has_feature = try loadProc(lib, FnAdapterHasFeature, "wgpuAdapterHasFeature"),
        .adapter_release = try loadProc(lib, FnAdapterRelease, "wgpuAdapterRelease"),
        .device_get_queue = try loadProc(lib, FnDeviceGetQueue, "wgpuDeviceGetQueue"),
        .device_destroy = try loadProc(lib, FnDeviceDestroy, "wgpuDeviceDestroy"),
        .device_release = try loadProc(lib, FnDeviceRelease, "wgpuDeviceRelease"),
        .queue_release = try loadProc(lib, FnQueueRelease, "wgpuQueueRelease"),
        .queue_submit = try loadProc(lib, FnQueueSubmit, "wgpuQueueSubmit"),
        .queue_write_buffer = try loadProc(lib, FnQueueWriteBuffer, "wgpuQueueWriteBuffer"),
        .queue_on_submitted_work_done = try loadProc(lib, FnQueueOnSubmittedWorkDone, "wgpuQueueOnSubmittedWorkDone"),
        .buffer_release = try loadProc(lib, FnBufferRelease, "wgpuBufferRelease"),
        .device_create_buffer = try loadProc(lib, FnDeviceCreateBuffer, "wgpuDeviceCreateBuffer"),
        .device_create_shader_module = try loadProc(lib, FnDeviceCreateShaderModule, "wgpuDeviceCreateShaderModule"),
        .shader_module_release = try loadProc(lib, FnShaderModuleRelease, "wgpuShaderModuleRelease"),
        .device_create_bind_group_layout = try loadProc(lib, FnDeviceCreateBindGroupLayout, "wgpuDeviceCreateBindGroupLayout"),
        .bind_group_layout_release = try loadProc(lib, FnBindGroupLayoutRelease, "wgpuBindGroupLayoutRelease"),
        .device_create_bind_group = try loadProc(lib, FnDeviceCreateBindGroup, "wgpuDeviceCreateBindGroup"),
        .bind_group_release = try loadProc(lib, FnBindGroupRelease, "wgpuBindGroupRelease"),
        .device_create_pipeline_layout = try loadProc(lib, FnDeviceCreatePipelineLayout, "wgpuDeviceCreatePipelineLayout"),
        .pipeline_layout_release = try loadProc(lib, FnPipelineLayoutRelease, "wgpuPipelineLayoutRelease"),
        .device_create_compute_pipeline = try loadProc(lib, FnDeviceCreateComputePipeline, "wgpuDeviceCreateComputePipeline"),
        .compute_pipeline_release = try loadProc(lib, FnComputePipelineRelease, "wgpuComputePipelineRelease"),
        .device_create_command_encoder = try loadProc(lib, FnDeviceCreateCommandEncoder, "wgpuDeviceCreateCommandEncoder"),
        .command_encoder_release = try loadProc(lib, FnCommandEncoderRelease, "wgpuCommandEncoderRelease"),
        .command_encoder_begin_compute_pass = try loadProc(lib, FnCommandEncoderBeginComputePass, "wgpuCommandEncoderBeginComputePass"),
        .compute_pass_encoder_set_pipeline = try loadProc(lib, FnComputePassEncoderSetPipeline, "wgpuComputePassEncoderSetPipeline"),
        .compute_pass_encoder_set_bind_group = try loadProc(lib, FnComputePassEncoderSetBindGroup, "wgpuComputePassEncoderSetBindGroup"),
        .compute_pass_encoder_dispatch_workgroups = try loadProc(lib, FnComputePassEncoderDispatchWorkgroups, "wgpuComputePassEncoderDispatchWorkgroups"),
        .compute_pass_encoder_end = try loadProc(lib, FnComputePassEncoderEnd, "wgpuComputePassEncoderEnd"),
        .compute_pass_encoder_release = try loadProc(lib, FnComputePassEncoderRelease, "wgpuComputePassEncoderRelease"),
        .command_encoder_finish = try loadProc(lib, FnCommandEncoderFinish, "wgpuCommandEncoderFinish"),
        .command_buffer_release = try loadProc(lib, FnCommandBufferRelease, "wgpuCommandBufferRelease"),
        .instance_release = try loadProc(lib, FnInstanceRelease, "wgpuInstanceRelease"),
    };
}

fn loadProc(lib: std.DynLib, comptime T: type, comptime name: [:0]const u8) !T {
    var mutable = lib;
    return mutable.lookup(T, name) orelse error.SymbolMissing;
}

pub fn semanticOpId(seq: u64, buffer: *[32]u8) []const u8 {
    const written = std.fmt.bufPrint(buffer, "step-{d:0>6}", .{seq}) catch return "step";
    return written;
}

pub fn bufferBindingTypeFor(buffer_type: dawn_plan_types.BufferBindingType) c.WGPUBufferBindingType {
    return switch (buffer_type) {
        .uniform => c.WGPUBufferBindingType_Uniform,
        .storage => c.WGPUBufferBindingType_Storage,
        .read_only_storage => c.WGPUBufferBindingType_ReadOnlyStorage,
    };
}

pub fn bufferUsageForBinding(buffer_type: dawn_plan_types.BufferBindingType) c.WGPUBufferUsage {
    return switch (buffer_type) {
        .uniform => c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst,
        .storage, .read_only_storage => c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopyDst,
    };
}

pub fn bufferUsageForWrite() c.WGPUBufferUsage {
    return c.WGPUBufferUsage_CopyDst;
}

pub fn pipelineKey(source: []const u8, entry_point: []const u8, bindings: []const dawn_plan_types.KernelBinding) u64 {
    var state: u64 = HASH_SEED;
    state = hashBytes(state, source);
    state = hashBytes(state, entry_point);
    for (bindings) |binding| {
        state = hashBytes(state, std.mem.asBytes(&binding.group));
        state = hashBytes(state, std.mem.asBytes(&binding.binding));
        state = hashBytes(state, std.mem.asBytes(&binding.resource_handle));
        state = hashBytes(state, std.mem.asBytes(&binding.buffer_size));
        state = hashBytes(state, std.mem.asBytes(&@intFromEnum(binding.buffer_type)));
    }
    return state;
}

pub fn mergeSpec(spec: *BufferSpec, size: u64, usage: c.WGPUBufferUsage) void {
    if (size > spec.size) spec.size = size;
    spec.usage |= usage;
}

pub fn collectBufferSpecs(
    allocator: std.mem.Allocator,
    plan: dawn_plan_types.Plan,
) !std.AutoHashMap(u64, BufferSpec) {
    var specs = std.AutoHashMap(u64, BufferSpec).init(allocator);
    errdefer specs.deinit();
    for (plan.commands) |command| {
        switch (command) {
            .buffer_write => |bw| {
                const data_bytes = @as(u64, bw.data.len) * 4;
                const size = if (bw.buffer_size > 0) @max(bw.buffer_size, bw.offset + data_bytes) else bw.offset + data_bytes;
                if (size == 0) return error.InvalidPlan;
                const entry = try specs.getOrPut(bw.handle);
                if (!entry.found_existing) entry.value_ptr.* = .{ .size = 0, .usage = 0 };
                mergeSpec(entry.value_ptr, size, bufferUsageForWrite());
            },
            .buffer_load => |bl| {
                const size = if (bl.buffer_size > 0) @max(bl.buffer_size, bl.offset + bl.byte_length) else bl.offset + bl.byte_length;
                if (size == 0) return error.InvalidPlan;
                const entry = try specs.getOrPut(bl.handle);
                if (!entry.found_existing) entry.value_ptr.* = .{ .size = 0, .usage = 0 };
                mergeSpec(entry.value_ptr, size, bufferUsageForWrite());
            },
            .kernel_dispatch => |kd| {
                for (kd.bindings) |binding| {
                    if (binding.group != 0) return error.UnsupportedCommand;
                    if (binding.buffer_size == 0) return error.InvalidPlan;
                    const entry = try specs.getOrPut(binding.resource_handle);
                    if (!entry.found_existing) entry.value_ptr.* = .{ .size = 0, .usage = 0 };
                    mergeSpec(entry.value_ptr, binding.buffer_size, bufferUsageForBinding(binding.buffer_type));
                }
            },
        }
    }
    return specs;
}

pub fn loadKernelRoot(allocator: std.mem.Allocator, ir_path: []const u8) ![]const u8 {
    const ir_bytes = std.fs.cwd().readFileAlloc(allocator, ir_path, 8 * 1024 * 1024) catch {
        return allocator.dupe(u8, DEFAULT_KERNEL_ROOT);
    };
    defer allocator.free(ir_bytes);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), ir_bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    switch (parsed.value) {
        .object => |object| {
            const root = object.get("shared") orelse return allocator.dupe(u8, DEFAULT_KERNEL_ROOT);
            switch (root) {
                .object => |shared| {
                    if (shared.get("kernelRoot")) |value| {
                        if (value == .string) return allocator.dupe(u8, value.string);
                    }
                },
                else => {},
            }
        },
        else => {},
    }
    return allocator.dupe(u8, DEFAULT_KERNEL_ROOT);
}

pub fn loadKernelSource(allocator: std.mem.Allocator, kernel_root: []const u8, kernel: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ kernel_root, kernel });
    defer allocator.free(path);
    return std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
}

pub fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11...12, 14...31 => try writer.print("\\u00{x:0>2}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub fn emptyStringView() c.WGPUStringView {
    return .{ .data = null, .length = 0 };
}

pub fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

pub fn elapsedSince(start_ns: u64) u64 {
    return nowNs() - start_ns;
}

pub fn hashByte(previous: u64, byte: u8) u64 {
    return (previous ^ @as(u64, byte)) *% 1099511628211;
}

pub fn hashBytes(previous: u64, bytes: []const u8) u64 {
    var state = previous;
    for (bytes) |byte| state = hashByte(state, byte);
    return state;
}

pub fn rowHash(previous_hash: u64, result: StepResult) u64 {
    var state = previous_hash;
    var semantic_buf: [32]u8 = undefined;
    const semantic_op_id = semanticOpId(result.seq, &semantic_buf);
    state = hashBytes(state, std.mem.asBytes(&result.seq));
    state = hashBytes(state, result.command_kind);
    state = hashBytes(state, semantic_op_id);
    state = hashBytes(state, result.semantic_stage);
    state = hashBytes(state, result.semantic_phase);
    state = hashBytes(state, result.status);
    state = hashBytes(state, result.status_code);
    state = hashBytes(state, result.status_message);
    state = hashBytes(state, result.execution_backend);
    state = hashBytes(state, result.backend_id);
    state = hashBytes(state, result.backend_lane);
    state = hashBytes(state, result.plan_hash);
    if (result.kernel) |kernel| state = hashBytes(state, kernel) else state = hashByte(state, 0);
    state = hashBytes(state, std.mem.asBytes(&result.dispatch_count));
    state = hashBytes(state, std.mem.asBytes(&result.submit_count));
    return state;
}

pub fn ensureParentDir(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;
    try std.fs.cwd().makePath(dir);
}

fn waitSleep() void {
    std.Thread.sleep(std.time.ns_per_ms);
}

pub fn waitForFlag(
    instance: c.WGPUInstance,
    process_events: FnInstanceProcessEvents,
    done: *const bool,
    timeout_ns: u64,
) !void {
    const start = nowNs();
    while (!done.*) {
        process_events(instance);
        if (nowNs() - start >= timeout_ns) return error.WaitTimedOut;
        waitSleep();
    }
}

pub fn requestAdapterCallback(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const state = @as(*AdapterState, @ptrCast(@alignCast(userdata1.?)));
    state.done = true;
    state.status = status;
    state.adapter = adapter;
}

pub fn requestDeviceCallback(
    status: c.WGPURequestDeviceStatus,
    device: c.WGPUDevice,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const state = @as(*DeviceState, @ptrCast(@alignCast(userdata1.?)));
    state.done = true;
    state.status = status;
    state.device = device;
}

pub fn queueDoneCallback(
    status: c.WGPUQueueWorkDoneStatus,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const state = @as(*WaitState, @ptrCast(@alignCast(userdata1.?)));
    state.done = true;
    state.status = status;
}
