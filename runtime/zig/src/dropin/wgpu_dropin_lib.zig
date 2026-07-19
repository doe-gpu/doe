const std = @import("std");
const abi_base = @import("../core/abi/wgpu_handle_types.zig");
const loader = @import("../core/abi/wgpu_loader.zig");
const p1_capability_procs = @import("../core/abi/procs/wgpu_p1_capability_procs.zig");
const dropin_ext_a = @import("wgpu_dropin_ext_a.zig");
const dropin_ext_b = @import("wgpu_dropin_ext_b.zig");
const dropin_ext_c = @import("wgpu_dropin_ext_c.zig");
const dropin_symbol_ownership = @import("dropin_symbol_ownership.zig");
const dropin_proc_manifest = @import("dropin_proc_manifest.zig");
const dropin_runtime_config = @import("dropin_runtime_config.zig");
const dropin_router = @import("dropin_router.zig");
const dropin_diagnostics = @import("dropin_diagnostics.zig");
const dropin_abi_procs = @import("dropin_abi_procs.zig");
const dropin_browser_shared_memory = @import("dropin_browser_shared_memory.zig");
const dropin_build_info = @import("dropin_build_info.zig");
const compute_fast = @import("../native/compute/doe_compute_fast.zig");

const build_options = @import("build_options");
pub const BuildTier = @TypeOf(build_options.build_tier);
pub const TIER = build_options.build_tier;

comptime {
    _ = dropin_ext_a;
    _ = dropin_ext_b;
    _ = dropin_ext_c;
    _ = dropin_symbol_ownership;
    _ = dropin_router;
    _ = dropin_diagnostics;
    _ = dropin_browser_shared_memory;
    _ = dropin_build_info;
    _ = @import("../native/mod.zig");
    if (@import("builtin").os.tag == .macos) {
        // Multi-queue management: doeNativeMultiQueueDevice*, doeNativeQueueSubmit, etc.
        _ = @import("../runtime/queue/multi_queue.zig");
    }
}

fn symbolRouteForName(symbol: []const u8) dropin_router.RouteDecision {
    return dropin_runtime_config.symbolRouteForName(symbol);
}

fn symbolNameSlice(name: abi_base.WGPUStringView) ?[]const u8 {
    return dropin_runtime_config.symbolNameSlice(name);
}

fn symbolRouteForView(name: abi_base.WGPUStringView) dropin_router.RouteDecision {
    return dropin_runtime_config.symbolRouteForView(name);
}

pub const DropinErrorCode = enum(u32) {
    ok = 0,
    library_open_failed = 1,
    symbol_missing = 2,
    invalid_symbol_name = 3,
    symbol_name_too_long = 4,
};

var g_state_lock: std.Thread.Mutex = .{};
var g_native_lib: ?std.DynLib = null;
var g_library_ready: bool = false;
var g_library_failed: bool = false;
var g_last_error_code = std.atomic.Value(u32).init(@intFromEnum(DropinErrorCode.ok));
const WgpuAnyProc = *const fn () callconv(.c) void;

fn setLastError(code: DropinErrorCode) void {
    g_last_error_code.store(@intFromEnum(code), .monotonic);
}

pub export fn doeWgpuDropinLastErrorCode() callconv(.c) u32 {
    return g_last_error_code.load(.monotonic);
}

pub export fn doeWgpuDropinClearLastError() callconv(.c) void {
    setLastError(.ok);
}

pub export fn doeNativeComputePrewarmDispatchBindings(
    q_raw: ?*anyopaque,
    dispatch_count: usize,
    pipe_ptrs: [*]?*anyopaque,
    bg_ptrs: [*]?*anyopaque,
    bg_counts: [*]const u32,
) callconv(.c) u32 {
    return compute_fast.prewarmDispatchBindingsForQueue(
        q_raw,
        dispatch_count,
        pipe_ptrs,
        bg_ptrs,
        bg_counts,
    );
}

pub export fn doeNativeComputeDispatchFlushOneBindGroup(
    q_raw: ?*anyopaque,
    pipe_raw: ?*anyopaque,
    bg0_raw: ?*anyopaque,
    dx: u32,
    dy: u32,
    dz: u32,
    copy_src: ?*anyopaque,
    copy_src_off: u64,
    copy_dst: ?*anyopaque,
    copy_dst_off: u64,
    copy_size: u64,
) callconv(.c) void {
    var bg_ptrs = [_]?*anyopaque{bg0_raw};
    compute_fast.computeDispatchFlushDirect(
        q_raw,
        pipe_raw,
        &bg_ptrs,
        bg_ptrs.len,
        dx,
        dy,
        dz,
        copy_src,
        copy_src_off,
        copy_dst,
        copy_dst_off,
        copy_size,
        null,
    );
}

fn ensureNativeLibraryLocked() bool {
    if (g_library_ready) return !g_library_failed;
    g_library_ready = true;
    g_native_lib = loader.openDropinTargetLibrary() catch {
        g_library_failed = true;
        setLastError(.library_open_failed);
        return false;
    };
    g_library_failed = false;
    return true;
}

fn ensureNativeLibrary() bool {
    g_state_lock.lock();
    defer g_state_lock.unlock();
    return ensureNativeLibraryLocked();
}

fn abortMissingRequiredSymbol(symbol_name: []const u8) noreturn {
    setLastError(.symbol_missing);
    std.debug.panic("missing required WebGPU symbol: {s}", .{symbol_name});
}

pub export fn doeWgpuDropinAbortMissingRequiredSymbol(name: abi_base.WGPUStringView) callconv(.c) noreturn {
    const symbol_name = symbolNameSlice(name) orelse {
        setLastError(.invalid_symbol_name);
        std.debug.panic("missing required WebGPU symbol: <invalid>", .{});
    };
    abortMissingRequiredSymbol(symbol_name);
}

fn routeAndRecordForName(
    symbol_name: []const u8,
    route: dropin_router.RouteDecision,
    resolved: bool,
) void {
    const diagnostics_owner = dropin_proc_manifest.manifestOwnerForSymbol(symbol_name) orelse
        dropin_runtime_config.symbolOwnerForName(symbol_name);
    dropin_diagnostics.record(
        symbol_name,
        dropin_symbol_ownership.symbol_owner_name(diagnostics_owner),
        resolved,
        route.fallback_used,
    );
}

fn nativeFromSymbol(comptime FnType: type, comptime symbol_name: [:0]const u8) ?FnType {
    // Direct lookup without re-acquiring g_state_lock (caller already holds it).
    if (g_native_lib == null) return null;
    var lib = g_native_lib.?;
    return lib.lookup(FnType, symbol_name);
}

/// Resolve a standard wgpu* symbol to the corresponding doeNative* implementation.
/// Returns null for symbols not yet implemented natively.
fn resolveDoeNativeProc(comptime FnType: type, comptime symbol_name: [:0]const u8) ?FnType {
    return dropin_proc_manifest.resolveDoeNativeProc(FnType, symbol_name);
}

pub fn loadRequiredProc(comptime FnType: type, comptime symbol_name: [:0]const u8) FnType {
    const Cache = struct {
        const symbol_key = symbol_name;
        var initialized = std.atomic.Value(u8).init(0);
        var proc: ?FnType = null;
    };
    _ = Cache.symbol_key;

    if (Cache.initialized.load(.acquire) != 0) {
        return Cache.proc.?;
    }

    g_state_lock.lock();
    defer g_state_lock.unlock();

    if (Cache.initialized.load(.monotonic) != 0) {
        return Cache.proc.?;
    }
    const route = symbolRouteForName(symbol_name);

    // For doe_metal or shared owner, try linked native implementations first (no sidecar needed).
    if (route.owner == .doe_metal or route.owner == .shared) {
        if (resolveDoeNativeProc(FnType, symbol_name)) |proc| {
            routeAndRecordForName(symbol_name, route, true);
            Cache.proc = proc;
            Cache.initialized.store(1, .release);
            setLastError(.ok);
            return proc;
        }
    }

    if (!ensureNativeLibraryLocked()) {
        routeAndRecordForName(symbol_name, route, false);
        abortMissingRequiredSymbol(symbol_name);
    }

    const resolved = switch (route.owner) {
        .dawn_delegate, .shared => nativeFromSymbol(FnType, symbol_name),
        .doe_metal, .doe_vulkan, .doe_d3d12 => if (route.fallback_used) nativeFromSymbol(FnType, symbol_name) else null,
    };

    routeAndRecordForName(symbol_name, route, resolved != null);
    if (resolved) |proc| {
        Cache.proc = proc;
        Cache.initialized.store(1, .release);
        setLastError(.ok);
        return proc;
    }
    abortMissingRequiredSymbol(symbol_name);
}

fn loadOptionalProc(comptime FnType: type, comptime symbol_name: [:0]const u8) ?FnType {
    const Cache = struct {
        const symbol_key = symbol_name;
        var initialized = std.atomic.Value(u8).init(0);
        var proc: ?FnType = null;
    };
    _ = Cache.symbol_key;

    if (Cache.initialized.load(.acquire) != 0) {
        return Cache.proc;
    }

    g_state_lock.lock();
    defer g_state_lock.unlock();

    if (Cache.initialized.load(.monotonic) != 0) {
        return Cache.proc;
    }

    if (!ensureNativeLibraryLocked()) return null;
    var lib = g_native_lib.?;
    Cache.proc = lib.lookup(FnType, symbol_name);
    Cache.initialized.store(1, .release);
    return Cache.proc;
}

fn fnPtr(value: anytype) p1_capability_procs.WGPUProc {
    return @as(p1_capability_procs.WGPUProc, @ptrCast(value));
}

fn symbolViewEq(name: abi_base.WGPUStringView, comptime expected: []const u8) bool {
    const data = name.data orelse return false;
    if (name.length == abi_base.WGPU_STRLEN) {
        const z = @as([*:0]const u8, @ptrCast(data));
        return std.mem.eql(u8, std.mem.span(z), expected);
    }
    if (name.length != expected.len) return false;
    return std.mem.eql(u8, data[0..name.length], expected);
}

fn toZeroTerminatedSymbolName(
    name: abi_base.WGPUStringView,
    buffer: *[256]u8,
) ?[:0]const u8 {
    const data = name.data orelse {
        setLastError(.invalid_symbol_name);
        return null;
    };

    if (name.length == abi_base.WGPU_STRLEN) {
        const z = @as([*:0]const u8, @ptrCast(data));
        return std.mem.span(z);
    }

    if (name.length == 0) {
        setLastError(.invalid_symbol_name);
        return null;
    }

    if (name.length >= buffer.len) {
        setLastError(.symbol_name_too_long);
        return null;
    }

    @memcpy(buffer[0..name.length], data[0..name.length]);
    buffer[name.length] = 0;
    return buffer[0..name.length :0];
}

fn resolveLocalProc(name: abi_base.WGPUStringView) p1_capability_procs.WGPUProc {
    const P = dropin_abi_procs;
    const N = @import("../native/mod.zig");
    if (symbolViewEq(name, "wgpuGetProcAddress")) return fnPtr(&wgpuGetProcAddress);
    if (symbolViewEq(name, "wgpuCreateInstance")) return fnPtr(&P.wgpuCreateInstance);
    if (symbolViewEq(name, "wgpuGetInstanceFeatures")) return fnPtr(&dropin_ext_a.exports.wgpuGetInstanceFeatures);
    if (symbolViewEq(name, "wgpuGetInstanceLimits")) return fnPtr(&dropin_ext_a.exports.wgpuGetInstanceLimits);
    if (symbolViewEq(name, "wgpuInstanceAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuInstanceAddRef);
    if (symbolViewEq(name, "wgpuInstanceRequestAdapter")) return fnPtr(&P.wgpuInstanceRequestAdapter);
    if (symbolViewEq(name, "wgpuInstanceWaitAny")) return fnPtr(&P.wgpuInstanceWaitAny);
    if (symbolViewEq(name, "wgpuInstanceProcessEvents")) return fnPtr(&P.wgpuInstanceProcessEvents);
    if (symbolViewEq(name, "wgpuAdapterAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuAdapterAddRef);
    if (symbolViewEq(name, "wgpuAdapterCreateDevice")) return fnPtr(&P.wgpuAdapterCreateDevice);
    if (symbolViewEq(name, "wgpuAdapterGetFeatures")) return fnPtr(&dropin_ext_a.exports.wgpuAdapterGetFeatures);
    if (symbolViewEq(name, "wgpuAdapterGetInfo")) return fnPtr(&dropin_ext_a.exports.wgpuAdapterGetInfo);
    if (symbolViewEq(name, "wgpuAdapterGetInstance")) return fnPtr(&dropin_ext_a.exports.wgpuAdapterGetInstance);
    if (symbolViewEq(name, "wgpuAdapterGetLimits")) return fnPtr(&dropin_ext_a.exports.wgpuAdapterGetLimits);
    if (symbolViewEq(name, "wgpuAdapterInfoFreeMembers")) return fnPtr(&dropin_ext_a.exports.wgpuAdapterInfoFreeMembers);
    if (symbolViewEq(name, "wgpuAdapterRequestDevice")) return fnPtr(&P.wgpuAdapterRequestDevice);
    if (symbolViewEq(name, "wgpuBindGroupAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuBindGroupAddRef);
    if (symbolViewEq(name, "wgpuBindGroupLayoutAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuBindGroupLayoutAddRef);
    if (symbolViewEq(name, "wgpuBindGroupLayoutSetLabel")) return fnPtr(&dropin_ext_c.wgpuBindGroupLayoutSetLabel);
    if (symbolViewEq(name, "wgpuBindGroupSetLabel")) return fnPtr(&dropin_ext_c.wgpuBindGroupSetLabel);
    if (symbolViewEq(name, "wgpuBufferAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuBufferAddRef);
    if (symbolViewEq(name, "wgpuBufferDestroy")) return fnPtr(&dropin_ext_a.exports.wgpuBufferDestroy);
    if (symbolViewEq(name, "wgpuBufferGetMappedRange")) return fnPtr(&N.doeNativeBufferGetMappedRange);
    if (symbolViewEq(name, "wgpuBufferGetMapState")) return fnPtr(&dropin_ext_c.wgpuBufferGetMapState);
    if (symbolViewEq(name, "wgpuBufferSetLabel")) return fnPtr(&dropin_ext_c.wgpuBufferSetLabel);
    if (symbolViewEq(name, "wgpuDeviceAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceAddRef);
    if (symbolViewEq(name, "wgpuDeviceCreateBuffer")) return fnPtr(&N.doeNativeDeviceCreateBuffer);
    if (symbolViewEq(name, "wgpuDeviceCreateShaderModule")) return fnPtr(&N.doeNativeDeviceCreateShaderModule);
    if (symbolViewEq(name, "wgpuCommandBufferAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuCommandBufferAddRef);
    if (symbolViewEq(name, "wgpuCommandBufferSetLabel")) return fnPtr(&dropin_ext_c.wgpuCommandBufferSetLabel);
    if (symbolViewEq(name, "wgpuCommandEncoderAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuCommandEncoderAddRef);
    if (symbolViewEq(name, "wgpuShaderModuleGetCompilationInfo")) return fnPtr(&dropin_ext_b.wgpuShaderModuleGetCompilationInfo);
    if (symbolViewEq(name, "wgpuShaderModuleRelease")) return fnPtr(&P.wgpuShaderModuleRelease);
    if (symbolViewEq(name, "wgpuCommandEncoderSetLabel")) return fnPtr(&dropin_ext_c.wgpuCommandEncoderSetLabel);
    if (symbolViewEq(name, "wgpuComputePassEncoderAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuComputePassEncoderAddRef);
    if (symbolViewEq(name, "wgpuComputePassEncoderSetLabel")) return fnPtr(&dropin_ext_c.wgpuComputePassEncoderSetLabel);
    if (symbolViewEq(name, "wgpuDeviceCreateComputePipeline")) return fnPtr(&N.doeNativeDeviceCreateComputePipeline);
    if (symbolViewEq(name, "wgpuDeviceCreateErrorBuffer")) return fnPtr(&dropin_browser_shared_memory.wgpuDeviceCreateErrorBuffer);
    if (symbolViewEq(name, "wgpuDeviceCreateErrorTexture")) return fnPtr(&dropin_browser_shared_memory.wgpuDeviceCreateErrorTexture);
    if (symbolViewEq(name, "wgpuComputePipelineAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuComputePipelineAddRef);
    if (symbolViewEq(name, "wgpuComputePipelineGetBindGroupLayout")) return fnPtr(&N.doeNativeComputePipelineGetBindGroupLayout);
    if (symbolViewEq(name, "wgpuComputePipelineSetLabel")) return fnPtr(&dropin_ext_c.wgpuComputePipelineSetLabel);
    if (symbolViewEq(name, "wgpuComputePipelineRelease")) return fnPtr(&P.wgpuComputePipelineRelease);
    if (symbolViewEq(name, "wgpuRenderPipelineRelease")) return fnPtr(&P.wgpuRenderPipelineRelease);
    if (symbolViewEq(name, "wgpuDeviceDestroy")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceDestroy);
    if (symbolViewEq(name, "wgpuDeviceCreateCommandEncoder")) return fnPtr(&N.doeNativeDeviceCreateCommandEncoder);
    if (symbolViewEq(name, "wgpuDevicePopErrorScope")) return fnPtr(&dropin_ext_a.exports.wgpuDevicePopErrorScope);
    if (symbolViewEq(name, "wgpuDevicePushErrorScope")) return fnPtr(&dropin_ext_a.exports.wgpuDevicePushErrorScope);
    if (symbolViewEq(name, "wgpuDeviceSetLabel")) return fnPtr(&dropin_ext_c.wgpuDeviceSetLabel);
    if (symbolViewEq(name, "wgpuDeviceSetLoggingCallback")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceSetLoggingCallback);
    if (symbolViewEq(name, "wgpuDeviceTick")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceTick);
    if (symbolViewEq(name, "wgpuCommandEncoderBeginComputePass")) return fnPtr(&N.doeNativeCommandEncoderBeginComputePass);
    if (symbolViewEq(name, "wgpuDeviceCreateRenderPipeline")) return fnPtr(&N.doeNativeDeviceCreateRenderPipeline);
    if (symbolViewEq(name, "wgpuCommandEncoderBeginRenderPass")) return fnPtr(&N.doeNativeCommandEncoderBeginRenderPass);
    if (symbolViewEq(name, "wgpuCommandEncoderClearBuffer")) return fnPtr(&dropin_ext_a.exports.wgpuCommandEncoderClearBuffer);
    if (symbolViewEq(name, "wgpuCommandEncoderInsertDebugMarker")) return fnPtr(&dropin_ext_c.wgpuCommandEncoderInsertDebugMarker);
    if (symbolViewEq(name, "wgpuCommandEncoderPopDebugGroup")) return fnPtr(&dropin_ext_c.wgpuCommandEncoderPopDebugGroup);
    if (symbolViewEq(name, "wgpuCommandEncoderPushDebugGroup")) return fnPtr(&dropin_ext_c.wgpuCommandEncoderPushDebugGroup);
    if (symbolViewEq(name, "wgpuCommandEncoderWriteBuffer")) return fnPtr(&dropin_ext_a.exports.wgpuCommandEncoderWriteBuffer);
    if (symbolViewEq(name, "wgpuCommandEncoderWriteTimestamp")) return fnPtr(&P.wgpuCommandEncoderWriteTimestamp);
    if (symbolViewEq(name, "wgpuCommandEncoderCopyBufferToBuffer")) return fnPtr(&N.doeNativeCopyBufferToBuffer);
    if (symbolViewEq(name, "wgpuCommandEncoderCopyBufferToTexture")) return fnPtr(&dropin_ext_b.doeAbiBridgeCopyBufferToTexture);
    if (symbolViewEq(name, "wgpuCommandEncoderCopyTextureToBuffer")) return fnPtr(&dropin_ext_b.doeAbiBridgeCopyTextureToBuffer);
    if (symbolViewEq(name, "wgpuCommandEncoderCopyTextureToTexture")) return fnPtr(&dropin_ext_b.doeAbiBridgeCopyTextureToTexture);
    if (symbolViewEq(name, "wgpuComputePassEncoderSetPipeline")) return fnPtr(&N.doeNativeComputePassSetPipeline);
    if (symbolViewEq(name, "wgpuComputePassEncoderSetBindGroup")) return fnPtr(&N.doeNativeComputePassSetBindGroup);
    if (symbolViewEq(name, "wgpuComputePassEncoderDispatchWorkgroups")) return fnPtr(&N.doeNativeComputePassDispatch);
    if (symbolViewEq(name, "wgpuComputePassEncoderEnd")) return fnPtr(&N.doeNativeComputePassEnd);
    if (symbolViewEq(name, "wgpuComputePassEncoderRelease")) return fnPtr(&P.wgpuComputePassEncoderRelease);
    if (symbolViewEq(name, "wgpuComputePassEncoderDispatchWorkgroupsIndirect")) return fnPtr(&dropin_ext_a.exports.wgpuComputePassEncoderDispatchWorkgroupsIndirect);
    if (symbolViewEq(name, "wgpuComputePassEncoderInsertDebugMarker")) return fnPtr(&dropin_ext_c.wgpuComputePassEncoderInsertDebugMarker);
    if (symbolViewEq(name, "wgpuComputePassEncoderPushDebugGroup")) return fnPtr(&dropin_ext_c.wgpuComputePassEncoderPushDebugGroup);
    if (symbolViewEq(name, "wgpuComputePassEncoderPopDebugGroup")) return fnPtr(&dropin_ext_c.wgpuComputePassEncoderPopDebugGroup);
    if (symbolViewEq(name, "wgpuComputePassEncoderSetImmediates")) return fnPtr(&dropin_ext_a.exports.wgpuComputePassEncoderSetImmediates);
    if (symbolViewEq(name, "wgpuComputePassEncoderWriteTimestamp")) return fnPtr(&dropin_ext_a.exports.wgpuComputePassEncoderWriteTimestamp);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetPipeline")) return fnPtr(&N.doeNativeRenderPassSetPipeline);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetVertexBuffer")) return fnPtr(&N.doeNativeRenderPassSetVertexBuffer);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetIndexBuffer")) return fnPtr(&N.doeNativeRenderPassSetIndexBuffer);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetBindGroup")) return fnPtr(&N.doeNativeRenderPassSetBindGroup);
    if (symbolViewEq(name, "wgpuRenderPassEncoderDraw")) return fnPtr(&N.doeNativeRenderPassDraw);
    if (symbolViewEq(name, "wgpuRenderPassEncoderDrawIndexed")) return fnPtr(&N.doeNativeRenderPassDrawIndexed);
    if (symbolViewEq(name, "wgpuRenderPassEncoderDrawIndirect")) return fnPtr(&N.doeNativeRenderPassDrawIndirect);
    if (symbolViewEq(name, "wgpuRenderPassEncoderDrawIndexedIndirect")) return fnPtr(&N.doeNativeRenderPassDrawIndexedIndirect);
    if (symbolViewEq(name, "wgpuRenderPassEncoderEnd")) return fnPtr(&N.doeNativeRenderPassEnd);
    if (symbolViewEq(name, "wgpuRenderPassEncoderRelease")) return fnPtr(&P.wgpuRenderPassEncoderRelease);
    if (symbolViewEq(name, "wgpuCommandEncoderFinish")) return fnPtr(&N.doeNativeCommandEncoderFinish);
    if (symbolViewEq(name, "wgpuDeviceGetAdapter")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceGetAdapter);
    if (symbolViewEq(name, "wgpuDeviceGetAdapterInfo")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceGetAdapterInfo);
    if (symbolViewEq(name, "wgpuDeviceGetFeatures")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceGetFeatures);
    if (symbolViewEq(name, "wgpuDeviceGetLimits")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceGetLimits);
    if (symbolViewEq(name, "wgpuDeviceGetQueue")) return fnPtr(&P.wgpuDeviceGetQueue);
    if (symbolViewEq(name, "wgpuDeviceImportSharedBufferMemory")) return fnPtr(&dropin_browser_shared_memory.wgpuDeviceImportSharedBufferMemory);
    if (symbolViewEq(name, "wgpuDeviceImportSharedFence")) return fnPtr(&dropin_browser_shared_memory.wgpuDeviceImportSharedFence);
    if (symbolViewEq(name, "wgpuDeviceImportSharedTextureMemory")) return fnPtr(&dropin_browser_shared_memory.wgpuDeviceImportSharedTextureMemory);
    if (symbolViewEq(name, "wgpuPipelineLayoutAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuPipelineLayoutAddRef);
    if (symbolViewEq(name, "wgpuPipelineLayoutSetLabel")) return fnPtr(&dropin_ext_c.wgpuPipelineLayoutSetLabel);
    if (symbolViewEq(name, "wgpuQuerySetAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuQuerySetAddRef);
    if (symbolViewEq(name, "wgpuQuerySetSetLabel")) return fnPtr(&dropin_ext_c.wgpuQuerySetSetLabel);
    if (symbolViewEq(name, "wgpuQueueAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuQueueAddRef);
    if (symbolViewEq(name, "wgpuQueueSetLabel")) return fnPtr(&dropin_ext_c.wgpuQueueSetLabel);
    if (symbolViewEq(name, "wgpuQueueSubmit")) return fnPtr(&P.wgpuQueueSubmit);
    if (symbolViewEq(name, "wgpuQueueOnSubmittedWorkDone")) return fnPtr(&P.wgpuQueueOnSubmittedWorkDone);
    if (symbolViewEq(name, "wgpuQueueWriteBuffer")) return fnPtr(&P.wgpuQueueWriteBuffer);
    if (symbolViewEq(name, "wgpuQueueWriteTexture")) return fnPtr(&dropin_ext_c.wgpuQueueWriteTexture);
    if (symbolViewEq(name, "wgpuQueueCopyExternalImageToTexture")) return fnPtr(&N.doeNativeQueueCopyExternalImageToTexture);
    if (symbolViewEq(name, "wgpuQueueCopyTextureForBrowser")) return fnPtr(&dropin_ext_c.wgpuQueueCopyTextureForBrowser);
    if (symbolViewEq(name, "wgpuQueueCopyExternalTextureForBrowser")) return fnPtr(&dropin_ext_c.wgpuQueueCopyExternalTextureForBrowser);
    if (symbolViewEq(name, "wgpuDeviceCreateTexture")) return fnPtr(&N.doeNativeDeviceCreateTexture);
    if (symbolViewEq(name, "wgpuDeviceValidateTextureDescriptor")) return fnPtr(&N.doeNativeDeviceValidateTextureDescriptor);
    if (symbolViewEq(name, "wgpuTextureCreateView")) return fnPtr(&N.doeNativeTextureCreateView);
    if (symbolViewEq(name, "wgpuRenderPassEncoderAddRef")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderAddRef);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetLabel")) return fnPtr(&dropin_ext_c.wgpuRenderPassEncoderSetLabel);
    if (symbolViewEq(name, "wgpuRenderPipelineAddRef")) return fnPtr(&dropin_ext_b.wgpuRenderPipelineAddRef);
    if (symbolViewEq(name, "wgpuRenderPipelineGetBindGroupLayout")) return fnPtr(&N.doeNativeRenderPipelineGetBindGroupLayout);
    if (symbolViewEq(name, "wgpuRenderPipelineSetLabel")) return fnPtr(&dropin_ext_c.wgpuRenderPipelineSetLabel);
    if (symbolViewEq(name, "wgpuSamplerAddRef")) return fnPtr(&dropin_ext_b.wgpuSamplerAddRef);
    if (symbolViewEq(name, "wgpuDeviceCreateBindGroupLayout")) return fnPtr(&N.doeNativeDeviceCreateBindGroupLayout);
    if (symbolViewEq(name, "wgpuBindGroupLayoutRelease")) return fnPtr(&P.wgpuBindGroupLayoutRelease);
    if (symbolViewEq(name, "wgpuDeviceCreateBindGroup")) return fnPtr(&N.doeNativeDeviceCreateBindGroup);
    if (symbolViewEq(name, "wgpuBindGroupRelease")) return fnPtr(&P.wgpuBindGroupRelease);
    if (symbolViewEq(name, "wgpuDeviceCreatePipelineLayout")) return fnPtr(&N.doeNativeDeviceCreatePipelineLayout);
    if (symbolViewEq(name, "wgpuPipelineLayoutRelease")) return fnPtr(&P.wgpuPipelineLayoutRelease);
    if (symbolViewEq(name, "wgpuSamplerSetLabel")) return fnPtr(&dropin_ext_c.wgpuSamplerSetLabel);
    if (symbolViewEq(name, "wgpuShaderModuleAddRef")) return fnPtr(&dropin_ext_b.wgpuShaderModuleAddRef);
    if (symbolViewEq(name, "wgpuShaderModuleSetLabel")) return fnPtr(&dropin_ext_c.wgpuShaderModuleSetLabel);
    if (symbolViewEq(name, "wgpuTextureAddRef")) return fnPtr(&dropin_ext_b.wgpuTextureAddRef);
    if (symbolViewEq(name, "wgpuTextureSetLabel")) return fnPtr(&dropin_ext_c.wgpuTextureSetLabel);
    if (symbolViewEq(name, "wgpuTextureDestroy")) return fnPtr(&N.doeNativeTextureDestroy);
    if (symbolViewEq(name, "wgpuTextureRelease")) return fnPtr(&P.wgpuTextureRelease);
    if (symbolViewEq(name, "wgpuTextureViewAddRef")) return fnPtr(&dropin_ext_b.wgpuTextureViewAddRef);
    if (symbolViewEq(name, "wgpuTextureViewSetLabel")) return fnPtr(&dropin_ext_c.wgpuTextureViewSetLabel);
    if (symbolViewEq(name, "wgpuTextureViewRelease")) return fnPtr(&P.wgpuTextureViewRelease);
    if (symbolViewEq(name, "wgpuInstanceRelease")) return fnPtr(&P.wgpuInstanceRelease);
    if (symbolViewEq(name, "wgpuAdapterRelease")) return fnPtr(&P.wgpuAdapterRelease);
    if (symbolViewEq(name, "wgpuDeviceRelease")) return fnPtr(&P.wgpuDeviceRelease);
    if (symbolViewEq(name, "wgpuQueueRelease")) return fnPtr(&P.wgpuQueueRelease);
    if (symbolViewEq(name, "wgpuCommandEncoderRelease")) return fnPtr(&P.wgpuCommandEncoderRelease);
    if (symbolViewEq(name, "wgpuCommandBufferRelease")) return fnPtr(&P.wgpuCommandBufferRelease);
    if (symbolViewEq(name, "wgpuBufferRelease")) return fnPtr(&P.wgpuBufferRelease);
    if (symbolViewEq(name, "wgpuAdapterHasFeature")) return fnPtr(&P.wgpuAdapterHasFeature);
    if (symbolViewEq(name, "wgpuDeviceHasFeature")) return fnPtr(&P.wgpuDeviceHasFeature);
    if (symbolViewEq(name, "wgpuDeviceCreateQuerySet")) return fnPtr(&P.wgpuDeviceCreateQuerySet);
    if (symbolViewEq(name, "wgpuQuerySetDestroy")) return fnPtr(&dropin_ext_a.exports.wgpuQuerySetDestroy);
    if (symbolViewEq(name, "wgpuQuerySetGetCount")) return fnPtr(&dropin_ext_a.exports.wgpuQuerySetGetCount);
    if (symbolViewEq(name, "wgpuQuerySetGetType")) return fnPtr(&dropin_ext_a.exports.wgpuQuerySetGetType);
    if (symbolViewEq(name, "wgpuCommandEncoderResolveQuerySet")) return fnPtr(&P.wgpuCommandEncoderResolveQuerySet);
    if (symbolViewEq(name, "wgpuQuerySetRelease")) return fnPtr(&P.wgpuQuerySetRelease);
    if (symbolViewEq(name, "wgpuRenderPassEncoderBeginOcclusionQuery")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderBeginOcclusionQuery);
    if (symbolViewEq(name, "wgpuRenderPassEncoderEndOcclusionQuery")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderEndOcclusionQuery);
    if (symbolViewEq(name, "wgpuBufferMapAsync")) return fnPtr(&N.doeNativeBufferMapAsync);
    if (symbolViewEq(name, "wgpuBufferGetConstMappedRange")) return fnPtr(&N.doeNativeBufferGetConstMappedRange);
    if (symbolViewEq(name, "wgpuBufferUnmap")) return fnPtr(&N.doeNativeBufferUnmap);
    if (symbolViewEq(name, "wgpuDeviceCreateSampler")) return fnPtr(&N.doeNativeDeviceCreateSampler);
    if (symbolViewEq(name, "wgpuSamplerRelease")) return fnPtr(&P.wgpuSamplerRelease);
    if (symbolViewEq(name, "wgpuSupportedFeaturesFreeMembers")) return fnPtr(&dropin_ext_b.wgpuSupportedFeaturesFreeMembers);
    if (symbolViewEq(name, "wgpuSupportedInstanceFeaturesFreeMembers")) return fnPtr(&dropin_ext_b.wgpuSupportedInstanceFeaturesFreeMembers);
    if (symbolViewEq(name, "wgpuDeviceCreateExternalTexture")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceCreateExternalTexture);
    if (symbolViewEq(name, "wgpuExternalTextureAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuExternalTextureAddRef);
    if (symbolViewEq(name, "wgpuExternalTextureDestroy")) return fnPtr(&dropin_ext_c.wgpuExternalTextureDestroy);
    if (symbolViewEq(name, "wgpuExternalTextureExpire")) return fnPtr(&dropin_ext_c.wgpuExternalTextureExpire);
    if (symbolViewEq(name, "wgpuExternalTextureRefresh")) return fnPtr(&dropin_ext_c.wgpuExternalTextureRefresh);
    if (symbolViewEq(name, "wgpuExternalTextureRelease")) return fnPtr(&dropin_ext_c.wgpuExternalTextureRelease);
    if (symbolViewEq(name, "wgpuExternalTextureSetLabel")) return fnPtr(&dropin_ext_c.wgpuExternalTextureSetLabel);
    if (symbolViewEq(name, "wgpuSharedBufferMemoryBeginAccess")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedBufferMemoryBeginAccess);
    if (symbolViewEq(name, "wgpuSharedBufferMemoryCreateBuffer")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedBufferMemoryCreateBuffer);
    if (symbolViewEq(name, "wgpuSharedBufferMemoryEndAccess")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedBufferMemoryEndAccess);
    if (symbolViewEq(name, "wgpuSharedBufferMemoryGetProperties")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedBufferMemoryGetProperties);
    if (symbolViewEq(name, "wgpuSharedBufferMemoryIsDeviceLost")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedBufferMemoryIsDeviceLost);
    if (symbolViewEq(name, "wgpuSharedBufferMemorySetLabel")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedBufferMemorySetLabel);
    if (symbolViewEq(name, "wgpuSharedBufferMemoryAddRef")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedBufferMemoryAddRef);
    if (symbolViewEq(name, "wgpuSharedBufferMemoryRelease")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedBufferMemoryRelease);
    if (symbolViewEq(name, "wgpuSharedBufferMemoryEndAccessStateFreeMembers")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedBufferMemoryEndAccessStateFreeMembers);
    if (symbolViewEq(name, "wgpuSharedFenceExportInfo")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedFenceExportInfo);
    if (symbolViewEq(name, "wgpuSharedFenceAddRef")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedFenceAddRef);
    if (symbolViewEq(name, "wgpuSharedFenceRelease")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedFenceRelease);
    if (symbolViewEq(name, "wgpuSharedFenceSetLabel")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedFenceSetLabel);
    if (symbolViewEq(name, "wgpuSharedTextureMemoryBeginAccess")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedTextureMemoryBeginAccess);
    if (symbolViewEq(name, "wgpuSharedTextureMemoryCreateTexture")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedTextureMemoryCreateTexture);
    if (symbolViewEq(name, "wgpuSharedTextureMemoryEndAccess")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedTextureMemoryEndAccess);
    if (symbolViewEq(name, "wgpuSharedTextureMemoryGetProperties")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedTextureMemoryGetProperties);
    if (symbolViewEq(name, "wgpuSharedTextureMemoryIsDeviceLost")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedTextureMemoryIsDeviceLost);
    if (symbolViewEq(name, "wgpuSharedTextureMemorySetLabel")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedTextureMemorySetLabel);
    if (symbolViewEq(name, "wgpuSharedTextureMemoryAddRef")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedTextureMemoryAddRef);
    if (symbolViewEq(name, "wgpuSharedTextureMemoryRelease")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedTextureMemoryRelease);
    if (symbolViewEq(name, "wgpuSharedTextureMemoryEndAccessStateFreeMembers")) return fnPtr(&dropin_browser_shared_memory.wgpuSharedTextureMemoryEndAccessStateFreeMembers);
    // Render bundle operations
    if (symbolViewEq(name, "wgpuDeviceCreateRenderBundleEncoder")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceCreateRenderBundleEncoder);
    if (symbolViewEq(name, "wgpuRenderBundleAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleAddRef);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderAddRef")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderAddRef);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderDraw")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderDraw);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderDrawIndexed")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderDrawIndexed);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderDrawIndexedIndirect")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderDrawIndexedIndirect);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderDrawIndirect")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderDrawIndirect);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderFinish")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderFinish);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderInsertDebugMarker")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderInsertDebugMarker);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderPopDebugGroup")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderPopDebugGroup);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderPushDebugGroup")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderPushDebugGroup);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderRelease")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderRelease);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderSetBindGroup")) return fnPtr(&dropin_ext_a.exports.wgpuRenderBundleEncoderSetBindGroup);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderSetImmediates")) return fnPtr(&dropin_ext_b.wgpuRenderBundleEncoderSetImmediates);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderSetIndexBuffer")) return fnPtr(&dropin_ext_b.wgpuRenderBundleEncoderSetIndexBuffer);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderSetPipeline")) return fnPtr(&dropin_ext_b.wgpuRenderBundleEncoderSetPipeline);
    if (symbolViewEq(name, "wgpuRenderBundleEncoderSetVertexBuffer")) return fnPtr(&dropin_ext_b.wgpuRenderBundleEncoderSetVertexBuffer);
    if (symbolViewEq(name, "wgpuRenderBundleRelease")) return fnPtr(&dropin_ext_b.wgpuRenderBundleRelease);
    if (symbolViewEq(name, "wgpuRenderPassEncoderExecuteBundles")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderExecuteBundles);
    if (symbolViewEq(name, "wgpuRenderPassEncoderInsertDebugMarker")) return fnPtr(&dropin_ext_c.wgpuRenderPassEncoderInsertDebugMarker);
    if (symbolViewEq(name, "wgpuRenderPassEncoderPopDebugGroup")) return fnPtr(&dropin_ext_c.wgpuRenderPassEncoderPopDebugGroup);
    if (symbolViewEq(name, "wgpuRenderPassEncoderPushDebugGroup")) return fnPtr(&dropin_ext_c.wgpuRenderPassEncoderPushDebugGroup);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetBlendConstant")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderSetBlendConstant);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetImmediates")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderSetImmediates);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetScissorRect")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderSetScissorRect);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetStencilReference")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderSetStencilReference);
    if (symbolViewEq(name, "wgpuRenderPassEncoderSetViewport")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderSetViewport);
    if (symbolViewEq(name, "wgpuRenderPassEncoderWriteTimestamp")) return fnPtr(&dropin_ext_b.wgpuRenderPassEncoderWriteTimestamp);
    // Async pipeline creation
    if (symbolViewEq(name, "wgpuDeviceCreateComputePipelineAsync")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceCreateComputePipelineAsync);
    if (symbolViewEq(name, "wgpuDeviceCreateRenderPipelineAsync")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceCreateRenderPipelineAsync);
    // Error scope and device lost
    if (symbolViewEq(name, "wgpuDeviceSetUncapturedErrorCallback")) return fnPtr(&dropin_ext_a.exports.wgpuDeviceSetUncapturedErrorCallback);
    if (symbolViewEq(name, "wgpuDeviceGetLostFuture")) return fnPtr(&dropin_ext_c.wgpuDeviceGetLostFuture);
    if (symbolViewEq(name, "wgpuDeviceSetDeviceLostCallback")) return fnPtr(&dropin_ext_c.wgpuDeviceSetDeviceLostCallback);
    // Surface procs
    if (symbolViewEq(name, "wgpuInstanceCreateSurface")) return fnPtr(&dropin_ext_a.exports.wgpuInstanceCreateSurface);
    if (symbolViewEq(name, "wgpuSurfaceConfigure")) return fnPtr(&dropin_ext_b.wgpuSurfaceConfigure);
    if (symbolViewEq(name, "wgpuSurfaceGetCapabilities")) return fnPtr(&dropin_ext_b.wgpuSurfaceGetCapabilities);
    if (symbolViewEq(name, "wgpuSurfaceGetCurrentTexture")) return fnPtr(&dropin_ext_b.wgpuSurfaceGetCurrentTexture);
    if (symbolViewEq(name, "wgpuSurfacePresent")) return fnPtr(&dropin_ext_b.wgpuSurfacePresent);
    if (symbolViewEq(name, "wgpuSurfaceRelease")) return fnPtr(&dropin_ext_b.wgpuSurfaceRelease);
    if (symbolViewEq(name, "wgpuSurfaceUnconfigure")) return fnPtr(&dropin_ext_b.wgpuSurfaceUnconfigure);
    if (symbolViewEq(name, "wgpuSurfaceCapabilitiesFreeMembers")) return fnPtr(&dropin_ext_b.wgpuSurfaceCapabilitiesFreeMembers);
    if (symbolViewEq(name, "wgpuSurfaceAddRef")) return fnPtr(&dropin_ext_b.wgpuSurfaceAddRef);
    if (symbolViewEq(name, "wgpuSurfaceSetLabel")) return fnPtr(&dropin_ext_c.wgpuSurfaceSetLabel);
    return null;
}

fn resolveNativeProc(name: abi_base.WGPUStringView) p1_capability_procs.WGPUProc {
    if (!ensureNativeLibrary()) return null;

    if (loadOptionalProc(p1_capability_procs.FnGetProcAddress, "wgpuGetProcAddress")) |native_get_proc_address| {
        const resolved = native_get_proc_address(name);
        if (resolved != null) return resolved;
    }

    var buffer: [256]u8 = undefined;
    const zname = toZeroTerminatedSymbolName(name, &buffer) orelse return null;

    g_state_lock.lock();
    defer g_state_lock.unlock();

    if (!ensureNativeLibraryLocked()) return null;
    var lib = g_native_lib.?;
    const resolved = lib.lookup(WgpuAnyProc, zname) orelse return null;
    return @as(p1_capability_procs.WGPUProc, resolved);
}

pub export fn wgpuGetProcAddress(name: abi_base.WGPUStringView) callconv(.c) p1_capability_procs.WGPUProc {
    const route = symbolRouteForView(name);
    const symbol_name = symbolNameSlice(name) orelse {
        setLastError(.invalid_symbol_name);
        return null;
    };

    // doe_metal proceeds to resolveLocalProc (which delegates to loadRequiredProc → resolveDoeNativeProc).
    if (route.owner == .doe_vulkan or route.owner == .doe_d3d12) {
        if (!route.fallback_used) {
            routeAndRecordForName(symbol_name, route, false);
            setLastError(.symbol_missing);
            return null;
        }
    }

    if (resolveLocalProc(name)) |proc| {
        routeAndRecordForName(symbol_name, route, route.owner == .dawn_delegate or route.owner == .shared or route.fallback_used);
        setLastError(.ok);
        return proc;
    }

    if (resolveNativeProc(name)) |proc| {
        routeAndRecordForName(symbol_name, route, true);
        setLastError(.ok);
        return proc;
    }

    routeAndRecordForName(symbol_name, route, false);
    setLastError(.symbol_missing);
    return null;
}

test "shared create proc routes to native implementation instead of recursive wrapper" {
    const N = @import("../native/mod.zig");
    const symbol: [:0]const u8 = "wgpuDeviceCreateBuffer";
    const view = abi_base.WGPUStringView{
        .data = symbol.ptr,
        .length = abi_base.WGPU_STRLEN,
    };

    try std.testing.expectEqual(fnPtr(&N.doeNativeDeviceCreateBuffer), resolveLocalProc(view));
    try std.testing.expectEqual(fnPtr(&N.doeNativeDeviceCreateBuffer), wgpuGetProcAddress(view));
    try std.testing.expect(resolveLocalProc(view) != fnPtr(&dropin_abi_procs.wgpuDeviceCreateBuffer));
}

test "shared compute pass proc routes to native implementation instead of recursive wrapper" {
    const N = @import("../native/mod.zig");
    const symbol: [:0]const u8 = "wgpuCommandEncoderBeginComputePass";
    const view = abi_base.WGPUStringView{
        .data = symbol.ptr,
        .length = abi_base.WGPU_STRLEN,
    };

    try std.testing.expectEqual(fnPtr(&N.doeNativeCommandEncoderBeginComputePass), resolveLocalProc(view));
    try std.testing.expectEqual(fnPtr(&N.doeNativeCommandEncoderBeginComputePass), wgpuGetProcAddress(view));
    try std.testing.expect(resolveLocalProc(view) != fnPtr(&dropin_abi_procs.wgpuCommandEncoderBeginComputePass));
}

test "shader compilation info resolves to Doe instead of Dawn" {
    const symbol: [:0]const u8 = "wgpuShaderModuleGetCompilationInfo";
    const view = abi_base.WGPUStringView{
        .data = symbol.ptr,
        .length = abi_base.WGPU_STRLEN,
    };

    try std.testing.expectEqual(fnPtr(&dropin_ext_b.wgpuShaderModuleGetCompilationInfo), resolveLocalProc(view));
    try std.testing.expectEqual(fnPtr(&dropin_ext_b.wgpuShaderModuleGetCompilationInfo), wgpuGetProcAddress(view));
}

test "texture descriptor validation resolves to Doe instead of Dawn" {
    const N = @import("../native/mod.zig");
    const symbol: [:0]const u8 = "wgpuDeviceValidateTextureDescriptor";
    const view = abi_base.WGPUStringView{
        .data = symbol.ptr,
        .length = abi_base.WGPU_STRLEN,
    };

    try std.testing.expectEqual(fnPtr(&N.doeNativeDeviceValidateTextureDescriptor), resolveLocalProc(view));
    try std.testing.expectEqual(fnPtr(&N.doeNativeDeviceValidateTextureDescriptor), wgpuGetProcAddress(view));
}

test "browser shared-memory procs resolve locally instead of native fallback" {
    const symbols = .{
        .{ "wgpuDeviceImportSharedTextureMemory", &dropin_browser_shared_memory.wgpuDeviceImportSharedTextureMemory },
        .{ "wgpuSharedTextureMemoryBeginAccess", &dropin_browser_shared_memory.wgpuSharedTextureMemoryBeginAccess },
        .{ "wgpuSharedTextureMemoryEndAccess", &dropin_browser_shared_memory.wgpuSharedTextureMemoryEndAccess },
        .{ "wgpuDeviceImportSharedBufferMemory", &dropin_browser_shared_memory.wgpuDeviceImportSharedBufferMemory },
        .{ "wgpuSharedBufferMemoryBeginAccess", &dropin_browser_shared_memory.wgpuSharedBufferMemoryBeginAccess },
        .{ "wgpuSharedFenceExportInfo", &dropin_browser_shared_memory.wgpuSharedFenceExportInfo },
        .{ "wgpuDeviceCreateErrorTexture", &dropin_browser_shared_memory.wgpuDeviceCreateErrorTexture },
        .{ "wgpuDeviceCreateErrorBuffer", &dropin_browser_shared_memory.wgpuDeviceCreateErrorBuffer },
    };

    inline for (symbols) |entry| {
        const symbol: [:0]const u8 = entry[0];
        const view = abi_base.WGPUStringView{
            .data = symbol.ptr,
            .length = abi_base.WGPU_STRLEN,
        };
        try std.testing.expectEqual(fnPtr(entry[1]), resolveLocalProc(view));
        try std.testing.expectEqual(fnPtr(entry[1]), wgpuGetProcAddress(view));
    }
}

comptime {
    _ = @import("dropin_abi_procs.zig");
}
