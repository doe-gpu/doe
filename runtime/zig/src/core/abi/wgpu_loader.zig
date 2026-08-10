const std = @import("std");
const builtin = @import("builtin");
const model_gpu_types = @import("../../contracts/model/model_texture_value_types.zig");
const proc_types = @import("wgpu_proc_types.zig");
const abi_base = proc_types.base;
const abi_descriptor = proc_types.descriptor;
const abi_records = @import("wgpu_runtime_records.zig");
const abi_proc_aliases = @import("wgpu_type_proc_aliases.zig");
const runtime_state = @import("wgpu_runtime_state_defs.zig");

pub const BUFFER_MAP_ASYNC_KEY: u64 = 0xFFFF_FFFF_FFFF_FFE0;

const DlInfo = extern struct {
    dli_fname: [*c]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: [*c]const u8,
    dli_saddr: ?*anyopaque,
};

extern fn dladdr(addr: *const anyopaque, info: *DlInfo) c_int;

pub const native_library_names = blk: {
    switch (builtin.os.tag) {
        .windows => break :blk &[_][]const u8{
            "webgpu_doe.dll",
            "webgpu.dll",
            "webgpu_dawn.dll",
            "webgpu-native.dll",
            "wgpu_native.dll",
        },
        .macos => break :blk &[_][]const u8{
            "libwebgpu_doe.dylib",
            "libwebgpu_dawn.dylib",
            "libwebgpu_webkit_cshim.dylib",
            "libwebgpu.dylib",
            "webgpu.dylib",
            "libwgpu_native.dylib",
        },
        else => break :blk &[_][]const u8{
            "libwebgpu_doe.so",
            "libwebgpu_dawn.so",
            "libwebgpu.so",
            "libwgpu_native.so",
            "libwgpu_native.so.0",
            "wgpu_native.so",
        },
    }
};

pub const dropin_target_library_names = blk: {
    switch (builtin.os.tag) {
        .windows => break :blk &[_][]const u8{
            "webgpu.dll",
            "webgpu_dawn.dll",
            "webgpu-native.dll",
            "wgpu_native.dll",
        },
        .macos => break :blk &[_][]const u8{
            "libwebgpu_dawn.dylib",
            "libwebgpu.dylib",
            "webgpu.dylib",
            "libwgpu_native.dylib",
        },
        else => break :blk &[_][]const u8{
            "libwebgpu_dawn.so",
            "libwebgpu.so",
            "libwgpu_native.so",
            "libwgpu_native.so.0",
            "wgpu_native.so",
        },
    }
};

pub const BUFFER_UPLOAD_KEY = 0xFFFF_FFFF_FFFF_FFFF;
pub const DEFAULT_TIMEOUT_NS = 2_000_000_000;
pub const QUEUE_WAIT_TIMEOUT_NS = 2_000_000_000;
pub const DEFAULT_WAIT_SLICE_NS = 50_000_000;
const FnAnySymbol = *const fn () callconv(.c) void;

pub const OPTIONAL_API_SURFACE_SYMBOLS = [_][:0]const u8{
    "wgpuBindGroupLayoutSetLabel",
    "wgpuBindGroupSetLabel",
    "wgpuBufferGetMapState",
    "wgpuBufferGetMappedRange",
    "wgpuBufferGetSize",
    "wgpuBufferGetUsage",
    "wgpuBufferReadMappedRange",
    "wgpuBufferSetLabel",
    "wgpuBufferWriteMappedRange",
    "wgpuCommandBufferSetLabel",
    "wgpuCommandEncoderInsertDebugMarker",
    "wgpuCommandEncoderPopDebugGroup",
    "wgpuCommandEncoderPushDebugGroup",
    "wgpuCommandEncoderSetLabel",
    "wgpuComputePassEncoderInsertDebugMarker",
    "wgpuComputePassEncoderPopDebugGroup",
    "wgpuComputePassEncoderPushDebugGroup",
    "wgpuComputePassEncoderSetLabel",
    "wgpuComputePipelineGetBindGroupLayout",
    "wgpuComputePipelineSetLabel",
    "wgpuDeviceGetLostFuture",
    "wgpuDeviceSetLabel",
    "wgpuExternalTextureRelease",
    "wgpuExternalTextureSetLabel",
    "wgpuPipelineLayoutSetLabel",
    "wgpuQuerySetSetLabel",
    "wgpuQueueSetLabel",
    "wgpuRenderPassEncoderInsertDebugMarker",
    "wgpuRenderPassEncoderPopDebugGroup",
    "wgpuRenderPassEncoderPushDebugGroup",
    "wgpuRenderPassEncoderSetLabel",
    "wgpuRenderPipelineSetLabel",
    "wgpuSamplerSetLabel",
    "wgpuShaderModuleSetLabel",
    "wgpuSurfaceSetLabel",
    "wgpuTextureSetLabel",
    "wgpuTextureViewSetLabel",
};

fn currentModuleDirectory(buffer: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (builtin.os.tag == .windows) return null;

    var info: DlInfo = std.mem.zeroes(DlInfo);
    const symbol_addr: *const anyopaque = @ptrCast(&openLibrary);
    if (dladdr(symbol_addr, &info) == 0) return null;

    const module_path_ptr = info.dli_fname;
    if (module_path_ptr == null) return null;
    const module_path = std.mem.span(module_path_ptr);
    const dir = std.fs.path.dirname(module_path) orelse return null;
    if (dir.len > buffer.len) return null;
    @memcpy(buffer[0..dir.len], dir);
    return buffer[0..dir.len];
}

fn openLibraryRelativeToModule(candidates: []const []const u8) ?std.DynLib {
    var module_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const module_dir = currentModuleDirectory(&module_dir_buf) orelse return null;

    var candidate_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (candidates) |candidate| {
        const full_path = std.fmt.bufPrint(
            &candidate_path_buf,
            "{s}" ++ std.fs.path.sep_str ++ "{s}",
            .{ module_dir, candidate },
        ) catch continue;
        const lib = std.DynLib.open(full_path) catch continue;
        return lib;
    }

    return null;
}

fn openLibraryFromWorkingTree(candidates: []const []const u8) ?std.DynLib {
    const cwd = std.fs.cwd();
    var candidate_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const candidate_dirs = [_][]const u8{
        "zig-out/lib",
        "runtime/zig/zig-out/lib",
    };

    for (candidate_dirs) |dir| {
        for (candidates) |candidate| {
            const full_path = std.fmt.bufPrint(
                &candidate_path_buf,
                "{s}" ++ std.fs.path.sep_str ++ "{s}",
                .{ dir, candidate },
            ) catch continue;
            cwd.access(full_path, .{}) catch continue;
            const lib = std.DynLib.open(full_path) catch continue;
            return lib;
        }
    }

    return null;
}

pub fn openLibrary() !std.DynLib {
    var last_err: ?anyerror = null;

    for (native_library_names) |candidate| {
        const lib = std.DynLib.open(candidate) catch |err| {
            last_err = err;
            continue;
        };
        return lib;
    }

    if (openLibraryRelativeToModule(native_library_names)) |lib| {
        return lib;
    }

    if (openLibraryFromWorkingTree(native_library_names)) |lib| {
        return lib;
    }

    if (last_err) |_| {}
    return error.LibraryOpenFailed;
}

pub fn openDropinTargetLibrary() !std.DynLib {
    var last_err: ?anyerror = null;

    for (dropin_target_library_names) |candidate| {
        const lib = std.DynLib.open(candidate) catch |err| {
            last_err = err;
            continue;
        };
        return lib;
    }

    if (openLibraryRelativeToModule(dropin_target_library_names)) |lib| {
        return lib;
    }

    if (openLibraryFromWorkingTree(dropin_target_library_names)) |lib| {
        return lib;
    }

    if (last_err) |_| {}
    return error.LibraryOpenFailed;
}

pub fn loadProcs(lib: std.DynLib) !abi_proc_aliases.Procs {
    const procs: abi_proc_aliases.Procs = .{
        .wgpuCreateInstance = try loadProc(lib, "wgpuCreateInstance", abi_proc_aliases.FnWgpuCreateInstance),
        .wgpuInstanceRequestAdapter = try loadProc(lib, "wgpuInstanceRequestAdapter", abi_proc_aliases.FnWgpuInstanceRequestAdapter),
        .wgpuInstanceWaitAny = try loadProc(lib, "wgpuInstanceWaitAny", abi_proc_aliases.FnWgpuInstanceWaitAny),
        .wgpuInstanceProcessEvents = try loadProc(lib, "wgpuInstanceProcessEvents", abi_proc_aliases.FnWgpuInstanceProcessEvents),
        .wgpuAdapterRequestDevice = try loadProc(lib, "wgpuAdapterRequestDevice", abi_proc_aliases.FnWgpuAdapterRequestDevice),
        .wgpuDeviceCreateBuffer = try loadProc(lib, "wgpuDeviceCreateBuffer", abi_proc_aliases.FnWgpuDeviceCreateBuffer),
        .wgpuDeviceCreateShaderModule = try loadProc(lib, "wgpuDeviceCreateShaderModule", abi_proc_aliases.FnWgpuDeviceCreateShaderModule),
        .wgpuShaderModuleRelease = try loadProc(lib, "wgpuShaderModuleRelease", abi_proc_aliases.FnWgpuShaderModuleRelease),
        .wgpuDeviceCreateComputePipeline = try loadProc(lib, "wgpuDeviceCreateComputePipeline", abi_proc_aliases.FnWgpuDeviceCreateComputePipeline),
        .wgpuComputePipelineGetBindGroupLayout = try loadProc(lib, "wgpuComputePipelineGetBindGroupLayout", abi_proc_aliases.FnWgpuComputePipelineGetBindGroupLayout),
        .wgpuComputePipelineRelease = try loadProc(lib, "wgpuComputePipelineRelease", abi_proc_aliases.FnWgpuComputePipelineRelease),
        .wgpuRenderPipelineRelease = try loadOptionalProc(lib, "wgpuRenderPipelineRelease", abi_proc_aliases.FnWgpuRenderPipelineRelease),
        .wgpuDeviceCreateCommandEncoder = try loadProc(lib, "wgpuDeviceCreateCommandEncoder", abi_proc_aliases.FnWgpuDeviceCreateCommandEncoder),
        .wgpuCommandEncoderBeginComputePass = try loadProc(lib, "wgpuCommandEncoderBeginComputePass", abi_proc_aliases.FnWgpuCommandEncoderBeginComputePass),
        .wgpuDeviceCreateRenderPipeline = try loadOptionalProc(lib, "wgpuDeviceCreateRenderPipeline", abi_proc_aliases.FnWgpuDeviceCreateRenderPipeline),
        .wgpuCommandEncoderBeginRenderPass = try loadOptionalProc(lib, "wgpuCommandEncoderBeginRenderPass", abi_proc_aliases.FnWgpuCommandEncoderBeginRenderPass),
        .wgpuCommandEncoderWriteTimestamp = try loadOptionalProc(lib, "wgpuCommandEncoderWriteTimestamp", abi_proc_aliases.FnWgpuCommandEncoderWriteTimestamp),
        .wgpuCommandEncoderCopyBufferToBuffer = try loadProc(lib, "wgpuCommandEncoderCopyBufferToBuffer", abi_proc_aliases.FnWgpuCommandEncoderCopyBufferToBuffer),
        .wgpuCommandEncoderCopyBufferToTexture = try loadProc(lib, "wgpuCommandEncoderCopyBufferToTexture", abi_proc_aliases.FnWgpuCommandEncoderCopyBufferToTexture),
        .wgpuCommandEncoderCopyTextureToBuffer = try loadProc(lib, "wgpuCommandEncoderCopyTextureToBuffer", abi_proc_aliases.FnWgpuCommandEncoderCopyTextureToBuffer),
        .wgpuCommandEncoderCopyTextureToTexture = try loadProc(lib, "wgpuCommandEncoderCopyTextureToTexture", abi_proc_aliases.FnWgpuCommandEncoderCopyTextureToTexture),
        .wgpuComputePassEncoderSetBindGroup = try loadProc(lib, "wgpuComputePassEncoderSetBindGroup", abi_proc_aliases.FnWgpuComputePassEncoderSetBindGroup),
        .wgpuComputePassEncoderSetPipeline = try loadProc(lib, "wgpuComputePassEncoderSetPipeline", abi_proc_aliases.FnWgpuComputePassEncoderSetPipeline),
        .wgpuComputePassEncoderDispatchWorkgroups = try loadProc(lib, "wgpuComputePassEncoderDispatchWorkgroups", abi_proc_aliases.FnWgpuComputePassEncoderDispatchWorkgroups),
        .wgpuComputePassEncoderEnd = try loadProc(lib, "wgpuComputePassEncoderEnd", abi_proc_aliases.FnWgpuComputePassEncoderEnd),
        .wgpuComputePassEncoderRelease = try loadProc(lib, "wgpuComputePassEncoderRelease", abi_proc_aliases.FnWgpuComputePassEncoderRelease),
        .wgpuRenderPassEncoderSetPipeline = try loadOptionalProc(lib, "wgpuRenderPassEncoderSetPipeline", abi_proc_aliases.FnWgpuRenderPassEncoderSetPipeline),
        .wgpuRenderPassEncoderSetVertexBuffer = try loadOptionalProc(lib, "wgpuRenderPassEncoderSetVertexBuffer", abi_proc_aliases.FnWgpuRenderPassEncoderSetVertexBuffer),
        .wgpuRenderPassEncoderSetIndexBuffer = try loadOptionalProc(lib, "wgpuRenderPassEncoderSetIndexBuffer", abi_proc_aliases.FnWgpuRenderPassEncoderSetIndexBuffer),
        .wgpuRenderPassEncoderSetBindGroup = try loadOptionalProc(lib, "wgpuRenderPassEncoderSetBindGroup", abi_proc_aliases.FnWgpuRenderPassEncoderSetBindGroup),
        .wgpuRenderPassEncoderDraw = try loadOptionalProc(lib, "wgpuRenderPassEncoderDraw", abi_proc_aliases.FnWgpuRenderPassEncoderDraw),
        .wgpuRenderPassEncoderDrawIndexed = try loadOptionalProc(lib, "wgpuRenderPassEncoderDrawIndexed", abi_proc_aliases.FnWgpuRenderPassEncoderDrawIndexed),
        .wgpuRenderPassEncoderDrawIndirect = try loadOptionalProc(lib, "wgpuRenderPassEncoderDrawIndirect", abi_proc_aliases.FnWgpuRenderPassEncoderDrawIndirect),
        .wgpuRenderPassEncoderDrawIndexedIndirect = try loadOptionalProc(lib, "wgpuRenderPassEncoderDrawIndexedIndirect", abi_proc_aliases.FnWgpuRenderPassEncoderDrawIndexedIndirect),
        .wgpuRenderPassEncoderEnd = try loadOptionalProc(lib, "wgpuRenderPassEncoderEnd", abi_proc_aliases.FnWgpuRenderPassEncoderEnd),
        .wgpuRenderPassEncoderRelease = try loadOptionalProc(lib, "wgpuRenderPassEncoderRelease", abi_proc_aliases.FnWgpuRenderPassEncoderRelease),
        .wgpuDeviceCreateTexture = try loadProc(lib, "wgpuDeviceCreateTexture", abi_proc_aliases.FnWgpuDeviceCreateTexture),
        .wgpuTextureCreateView = try loadProc(lib, "wgpuTextureCreateView", abi_proc_aliases.FnWgpuTextureCreateView),
        .wgpuDeviceCreateBindGroupLayout = try loadProc(lib, "wgpuDeviceCreateBindGroupLayout", abi_proc_aliases.FnWgpuDeviceCreateBindGroupLayout),
        .wgpuBindGroupLayoutRelease = try loadProc(lib, "wgpuBindGroupLayoutRelease", abi_proc_aliases.FnWgpuBindGroupLayoutRelease),
        .wgpuDeviceCreateBindGroup = try loadProc(lib, "wgpuDeviceCreateBindGroup", abi_proc_aliases.FnWgpuDeviceCreateBindGroup),
        .wgpuBindGroupRelease = try loadProc(lib, "wgpuBindGroupRelease", abi_proc_aliases.FnWgpuBindGroupRelease),
        .wgpuDeviceCreatePipelineLayout = try loadProc(lib, "wgpuDeviceCreatePipelineLayout", abi_proc_aliases.FnWgpuDeviceCreatePipelineLayout),
        .wgpuPipelineLayoutRelease = try loadProc(lib, "wgpuPipelineLayoutRelease", abi_proc_aliases.FnWgpuPipelineLayoutRelease),
        .wgpuTextureRelease = try loadProc(lib, "wgpuTextureRelease", abi_proc_aliases.FnWgpuTextureRelease),
        .wgpuTextureViewRelease = try loadProc(lib, "wgpuTextureViewRelease", abi_proc_aliases.FnWgpuTextureViewRelease),
        .wgpuCommandEncoderFinish = try loadProc(lib, "wgpuCommandEncoderFinish", abi_proc_aliases.FnWgpuCommandEncoderFinish),
        .wgpuDeviceGetQueue = try loadProc(lib, "wgpuDeviceGetQueue", abi_proc_aliases.FnWgpuDeviceGetQueue),
        .wgpuQueueSubmit = try loadProc(lib, "wgpuQueueSubmit", abi_proc_aliases.FnWgpuQueueSubmit),
        .wgpuQueueOnSubmittedWorkDone = try loadProc(lib, "wgpuQueueOnSubmittedWorkDone", abi_proc_aliases.FnWgpuQueueOnSubmittedWorkDone),
        .wgpuQueueWriteBuffer = try loadProc(lib, "wgpuQueueWriteBuffer", abi_proc_aliases.FnWgpuQueueWriteBuffer),
        .wgpuInstanceRelease = try loadProc(lib, "wgpuInstanceRelease", abi_proc_aliases.FnWgpuInstanceRelease),
        .wgpuAdapterRelease = try loadProc(lib, "wgpuAdapterRelease", abi_proc_aliases.FnWgpuAdapterRelease),
        .wgpuDeviceRelease = try loadProc(lib, "wgpuDeviceRelease", abi_proc_aliases.FnWgpuDeviceRelease),
        .wgpuQueueRelease = try loadProc(lib, "wgpuQueueRelease", abi_proc_aliases.FnWgpuQueueRelease),
        .wgpuCommandEncoderRelease = try loadProc(lib, "wgpuCommandEncoderRelease", abi_proc_aliases.FnWgpuCommandEncoderRelease),
        .wgpuCommandBufferRelease = try loadProc(lib, "wgpuCommandBufferRelease", abi_proc_aliases.FnWgpuCommandBufferRelease),
        .wgpuBufferRelease = try loadProc(lib, "wgpuBufferRelease", abi_proc_aliases.FnWgpuBufferRelease),
        .wgpuAdapterHasFeature = try loadProc(lib, "wgpuAdapterHasFeature", abi_proc_aliases.FnWgpuAdapterHasFeature),
        .wgpuDeviceHasFeature = try loadOptionalProc(lib, "wgpuDeviceHasFeature", abi_proc_aliases.FnWgpuDeviceHasFeature),
        .wgpuDeviceCreateQuerySet = try loadProc(lib, "wgpuDeviceCreateQuerySet", abi_proc_aliases.FnWgpuDeviceCreateQuerySet),
        .wgpuCommandEncoderResolveQuerySet = try loadProc(lib, "wgpuCommandEncoderResolveQuerySet", abi_proc_aliases.FnWgpuCommandEncoderResolveQuerySet),
        .wgpuQuerySetRelease = try loadProc(lib, "wgpuQuerySetRelease", abi_proc_aliases.FnWgpuQuerySetRelease),
        .wgpuBufferMapAsync = try loadProc(lib, "wgpuBufferMapAsync", abi_proc_aliases.FnWgpuBufferMapAsync),
        .wgpuBufferGetConstMappedRange = try loadProc(lib, "wgpuBufferGetConstMappedRange", abi_proc_aliases.FnWgpuBufferGetConstMappedRange),
        .wgpuBufferGetMappedRange = try loadProc(lib, "wgpuBufferGetMappedRange", abi_proc_aliases.FnWgpuBufferGetMappedRange),
        .wgpuBufferUnmap = try loadProc(lib, "wgpuBufferUnmap", abi_proc_aliases.FnWgpuBufferUnmap),
    };
    preloadOptionalApiSurfaceSymbols(lib);
    return procs;
}

pub fn preloadOptionalApiSurfaceSymbols(lib: std.DynLib) void {
    var mutable = lib;
    inline for (OPTIONAL_API_SURFACE_SYMBOLS) |name| {
        _ = mutable.lookup(FnAnySymbol, name);
    }
}

fn loadProc(
    lib: std.DynLib,
    comptime name: [:0]const u8,
    comptime T: type,
) !T {
    var mutable = lib;
    return mutable.lookup(T, name) orelse error.SymbolMissing;
}

fn loadOptionalProc(
    lib: std.DynLib,
    comptime name: [:0]const u8,
    comptime T: type,
) !?T {
    var mutable = lib;
    return mutable.lookup(T, name);
}

pub fn queueWorkDoneCallback(
    status: abi_descriptor.WGPUQueueWorkDoneStatus,
    message: abi_base.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const state = @as(*runtime_state.QueueSubmitState, @ptrCast(@alignCast(userdata1.?)));
    state.done = true;
    state.status = status;
}

pub fn adapterCallback(
    status: abi_descriptor.WGPURequestAdapterStatus,
    adapter: abi_base.WGPUAdapter,
    message: abi_base.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const state = @as(*abi_records.RequestState, @ptrCast(@alignCast(userdata1.?)));
    state.done = true;
    state.status = status;
    state.adapter = adapter;
}

pub fn deviceRequestCallback(
    status: abi_descriptor.WGPURequestDeviceStatus,
    device: abi_base.WGPUDevice,
    message: abi_base.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const state = @as(*abi_records.DeviceRequestState, @ptrCast(@alignCast(userdata1.?)));
    state.done = true;
    state.status = status;
    state.device = device;
}

pub fn bufferMapCallback(
    status: abi_base.WGPUMapAsyncStatus,
    message: abi_base.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    const state = @as(*runtime_state.BufferMapState, @ptrCast(@alignCast(userdata1.?)));
    state.done = true;
    state.status = status;
}

pub fn uncapturedErrorCallback(
    _: [*c]const abi_base.WGPUDevice,
    error_type: c_uint,
    message: abi_base.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    const state_ptr = userdata1 orelse return;
    const state = @as(*runtime_state.UncapturedErrorState, @ptrCast(@alignCast(state_ptr)));
    state.error_type.store(error_type, .release);
    state.pending.store(1, .release);
}

pub fn alignTo(value: u64, alignment: u64) u64 {
    if (alignment == 0) return value;
    const mask = alignment - 1;
    return (value + mask) & ~mask;
}

pub fn emptyStringView() abi_base.WGPUStringView {
    return abi_base.WGPUStringView{ .data = null, .length = abi_base.WGPU_STRLEN };
}

pub fn stringView(source: []const u8) abi_base.WGPUStringView {
    if (source.len == 0) return emptyStringView();
    return abi_base.WGPUStringView{
        .data = source.ptr,
        .length = source.len,
    };
}

pub fn normalizeCopyLayoutValue(raw_layout: u32) u32 {
    if (raw_layout == 0 or raw_layout == model_gpu_types.WGPUCopyStrideUndefined) return abi_base.WGPU_COPY_STRIDE_UNDEFINED;
    return raw_layout;
}

pub fn normalizeTextureAspect(raw_aspect: u32) abi_base.WGPUTextureAspect {
    return switch (raw_aspect) {
        model_gpu_types.WGPUTextureAspect_DepthOnly => abi_base.WGPUTextureAspect_DepthOnly,
        model_gpu_types.WGPUTextureAspect_StencilOnly => abi_base.WGPUTextureAspect_StencilOnly,
        else => abi_base.WGPUTextureAspect_All,
    };
}
