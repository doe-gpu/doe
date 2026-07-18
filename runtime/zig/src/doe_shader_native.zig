// doe_shader_native.zig — Shader module and compute pipeline creation for Doe native Metal backend.
// Sharded from doe_wgpu_native.zig: WGSL→MSL translation, MTLLibrary/MTLComputePipelineState creation.

const std = @import("std");
const abi_core = @import("core/abi/wgpu_core_base_types.zig");
const abi_callback = @import("core/abi/wgpu_callback_descriptor_types.zig");
const abi_pipeline = @import("core/abi/wgpu_pipeline_descriptor_types.zig");
const wgsl_compiler = @import("doe_wgsl/mod.zig");
const wgsl_ir = @import("doe_wgsl/ir.zig");
const wgsl_runtime_compile = @import("doe_wgsl/runtime_compile.zig");
const shader_translation_cache = @import("doe_shader_translation_cache.zig");
const package_metal_pipeline_cache = @import("doe_package_metal_pipeline_cache.zig");
const native_types = @import("doe_native_object_types.zig");
const native_shared = @import("doe_native_shared_types.zig");
const native_helpers = @import("doe_native_object_helpers.zig");
const bind_group = @import("doe_bind_group_native.zig");
const resource_ops = @import("backend/dropin_resource_ops.zig");
const bridge = resource_ops.metal_bridge;
const metal_bridge_device_new_compute_pipeline = bridge.metal_bridge_device_new_compute_pipeline;
const metal_bridge_device_new_library_msl = bridge.metal_bridge_device_new_library_msl;
const metal_bridge_library_new_function = bridge.metal_bridge_library_new_function;
const metal_bridge_retain = bridge.metal_bridge_retain;
const metal_bridge_release = bridge.metal_bridge_release;

const alloc = native_helpers.alloc;
const make = native_helpers.make;
const cast = native_helpers.cast;
const toOpaque = native_helpers.toOpaque;
const ERR_CAP = native_shared.ERR_CAP;
const label_store = native_helpers.label_store;

const DoeDevice = native_types.DoeDevice;
const DoeShaderModule = native_types.DoeShaderModule;
const DoeComputePipeline = native_types.DoeComputePipeline;
const DoePipelineLayout = native_types.DoePipelineLayout;
const DoeBindGroupLayout = native_types.DoeBindGroupLayout;
const CompilationMessageKind = native_shared.CompilationMessageKind;
const LAST_ERROR_CAP: usize = 512;
const LAST_ERROR_META_CAP: usize = 64;
const DIAGNOSTIC_DIRECTIVE_INFO: []const u8 =
    "WGSL diagnostic directives are parsed on this path and currently reported as advisory compilation info only.";
const WGSL_SHADER_MODULE_CACHE_MAX_ENTRIES: usize = 64;
var last_error_buf: [LAST_ERROR_CAP]u8 = undefined;
var last_error_len: usize = 0;
var last_error_stage_buf: [LAST_ERROR_META_CAP]u8 = undefined;
var last_error_stage_len: usize = 0;
var last_error_kind_buf: [LAST_ERROR_META_CAP]u8 = undefined;
var last_error_kind_len: usize = 0;
var last_error_line: u32 = 0;
var last_error_col: u32 = 0;

const WgslShaderModuleCacheEntry = struct {
    source_hash: [32]u8,
    mtl_library: *anyopaque,
    wg_x: u32,
    wg_y: u32,
    wg_z: u32,
    needs_sizes_buf: bool,
    dispatch_preconditions: []const wgsl_ir.DispatchPrecondition,
};

var wgsl_shader_module_cache_mutex = std.Thread.Mutex{};
var wgsl_shader_module_cache: std.ArrayListUnmanaged(WgslShaderModuleCacheEntry) = .{};

fn hash_wgsl_source(wgsl: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wgsl, &digest, .{});
    return digest;
}

fn clone_dispatch_preconditions(source: []const wgsl_ir.DispatchPrecondition) ?[]const wgsl_ir.DispatchPrecondition {
    if (source.len == 0) return &.{};
    return alloc.dupe(wgsl_ir.DispatchPrecondition, source) catch null;
}

fn tryCreateCachedWgslShaderModule(wgsl: []const u8, source_hash: [32]u8) ?*anyopaque {
    var cached: ?WgslShaderModuleCacheEntry = null;
    wgsl_shader_module_cache_mutex.lock();
    for (wgsl_shader_module_cache.items) |entry| {
        if (std.mem.eql(u8, entry.source_hash[0..], source_hash[0..])) {
            cached = entry;
            break;
        }
    }
    wgsl_shader_module_cache_mutex.unlock();

    const entry = cached orelse return null;
    const sm = make(DoeShaderModule) orelse return null;
    const dispatch_preconditions = clone_dispatch_preconditions(entry.dispatch_preconditions) orelse {
        alloc.destroy(sm);
        return null;
    };
    sm.* = .{
        .mtl_library = entry.mtl_library,
        .wg_x = entry.wg_x,
        .wg_y = entry.wg_y,
        .wg_z = entry.wg_z,
        .needs_sizes_buf = entry.needs_sizes_buf,
        .dispatch_preconditions = dispatch_preconditions,
        .wgsl_source = alloc.dupe(u8, wgsl) catch null,
        .mtl_library_borrowed = true,
    };
    set_module_info_from_diagnostic_directive(sm, wgsl);
    return toOpaque(sm);
}

fn storeWgslShaderModuleCache(source_hash: [32]u8, lib: ?*anyopaque, info: *const wgsl_runtime_compile.TranslationInfo) void {
    const library = lib orelse return;
    const dispatch_preconditions = clone_dispatch_preconditions(info.dispatch_preconditions) orelse return;

    wgsl_shader_module_cache_mutex.lock();
    defer wgsl_shader_module_cache_mutex.unlock();

    for (wgsl_shader_module_cache.items) |entry| {
        if (std.mem.eql(u8, entry.source_hash[0..], source_hash[0..])) {
            if (dispatch_preconditions.len > 0) alloc.free(dispatch_preconditions);
            return;
        }
    }
    if (wgsl_shader_module_cache.items.len >= WGSL_SHADER_MODULE_CACHE_MAX_ENTRIES) {
        if (dispatch_preconditions.len > 0) alloc.free(dispatch_preconditions);
        return;
    }
    const retained_library = metal_bridge_retain(library) orelse {
        if (dispatch_preconditions.len > 0) alloc.free(dispatch_preconditions);
        return;
    };
    wgsl_shader_module_cache.append(alloc, .{
        .source_hash = source_hash,
        .mtl_library = retained_library,
        .wg_x = info.workgroup_size[0],
        .wg_y = info.workgroup_size[1],
        .wg_z = info.workgroup_size[2],
        .needs_sizes_buf = info.needs_sizes_buf,
        .dispatch_preconditions = dispatch_preconditions,
    }) catch {
        metal_bridge_release(retained_library);
        if (dispatch_preconditions.len > 0) alloc.free(dispatch_preconditions);
    };
}

fn clear_last_error() void {
    last_error_len = 0;
    last_error_stage_len = 0;
    last_error_kind_len = 0;
    last_error_line = 0;
    last_error_col = 0;
}

fn set_last_error(message: []const u8) void {
    const len = @min(message.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..len], message[0..len]);
    last_error_buf[len] = 0;
    last_error_len = len;
}

fn set_last_error_fmt(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&last_error_buf, fmt, args) catch {
        last_error_len = 0;
        return;
    };
    last_error_len = text.len;
}

fn set_last_error_meta(buf: []u8, len_out: *usize, text: []const u8) void {
    const len = @min(text.len, buf.len - 1);
    @memcpy(buf[0..len], text[0..len]);
    buf[len] = 0;
    len_out.* = len;
}

fn set_last_error_stage_name(stage: []const u8) void {
    set_last_error_meta(&last_error_stage_buf, &last_error_stage_len, stage);
}

fn set_last_error_stage(stage: wgsl_compiler.CompilationStage) void {
    if (stage == .none) {
        last_error_stage_len = 0;
        return;
    }
    set_last_error_stage_name(@tagName(stage));
}

fn set_last_error_kind(kind: []const u8) void {
    set_last_error_meta(&last_error_kind_buf, &last_error_kind_len, kind);
}

fn capture_wgsl_error_location() void {
    last_error_line = wgsl_compiler.lastErrorLine();
    last_error_col = wgsl_compiler.lastErrorColumn();
}

pub export fn doeNativeCopyLastErrorMessage(out_ptr: ?[*]u8, out_len: usize) callconv(.c) usize {
    if (out_ptr == null or out_len == 0 or last_error_len == 0) return last_error_len;
    const dst = out_ptr.?[0..out_len];
    const copy_len = @min(last_error_len, out_len - 1);
    @memcpy(dst[0..copy_len], last_error_buf[0..copy_len]);
    dst[copy_len] = 0;
    return last_error_len;
}

pub export fn doeNativeCopyLastErrorStage(out_ptr: ?[*]u8, out_len: usize) callconv(.c) usize {
    if (out_ptr == null or out_len == 0 or last_error_stage_len == 0) return last_error_stage_len;
    const dst = out_ptr.?[0..out_len];
    const copy_len = @min(last_error_stage_len, out_len - 1);
    @memcpy(dst[0..copy_len], last_error_stage_buf[0..copy_len]);
    dst[copy_len] = 0;
    return last_error_stage_len;
}

pub export fn doeNativeCopyLastErrorKind(out_ptr: ?[*]u8, out_len: usize) callconv(.c) usize {
    if (out_ptr == null or out_len == 0 or last_error_kind_len == 0) return last_error_kind_len;
    const dst = out_ptr.?[0..out_len];
    const copy_len = @min(last_error_kind_len, out_len - 1);
    @memcpy(dst[0..copy_len], last_error_kind_buf[0..copy_len]);
    dst[copy_len] = 0;
    return last_error_kind_len;
}

pub export fn doeNativeGetLastErrorLine() callconv(.c) u32 {
    return last_error_line;
}

pub export fn doeNativeGetLastErrorColumn() callconv(.c) u32 {
    return last_error_col;
}

pub export fn doeNativeCheckShaderSource(code_ptr: ?[*]const u8, code_len: usize) callconv(.c) u32 {
    clear_last_error();
    const ptr = code_ptr orelse {
        set_last_error_stage_name("native_check");
        set_last_error_kind("InvalidInput");
        set_last_error("shader check failed: WGSL source pointer is null");
        return 0;
    };
    const wgsl = ptr[0..code_len];
    var msl_buf: [wgsl_compiler.MAX_OUTPUT]u8 = undefined;
    _ = wgsl_compiler.translateToMsl(alloc, wgsl, &msl_buf) catch |err| {
        set_last_error_stage(wgsl_compiler.lastErrorStage());
        set_last_error_kind(@errorName(err));
        capture_wgsl_error_location();
        const detail = wgsl_compiler.lastErrorMessage();
        if (detail.len > 0) {
            set_last_error(detail);
        } else {
            set_last_error_fmt("{s}: {s}", .{ @tagName(wgsl_compiler.lastErrorStage()), @errorName(err) });
        }
        return 0;
    };
    return 1;
}

pub export fn doeNativeShaderModuleGetBindings(raw: ?*anyopaque, out_ptr: ?[*]native_shared.BindingInfo, out_len: usize) callconv(.c) usize {
    const sm = cast(DoeShaderModule, raw) orelse return 0;
    ensureShaderBindings(sm);
    const count: usize = sm.binding_count;
    if (out_ptr) |out| {
        const copy_len = @min(count, out_len);
        @memcpy(out[0..copy_len], sm.bindings[0..copy_len]);
    }
    return count;
}

// ============================================================
// Shader Module — sType dispatch
// ============================================================

/// Resolve a WGPUStringView to a byte slice, handling WGPU_STRLEN sentinel.
fn resolveStringView(sv: abi_core.WGPUStringView) ?[]const u8 {
    const data = sv.data orelse return null;
    const len = if (sv.length == abi_core.WGPU_STRLEN)
        std.mem.len(@as([*:0]const u8, @ptrCast(data)))
    else
        sv.length;
    return data[0..len];
}

/// Normalize workgroup size from descriptor: 0 → 1 (unknown defaults to 1).
fn normalizeWorkgroupDim(v: u32) u32 {
    return if (v > 0) v else 1;
}

fn offset_to_line_column(src: []const u8, offset: usize) struct { line: u32, column: u32 } {
    var line: u32 = 1;
    var column: u32 = 1;
    var i: usize = 0;
    const clamped_offset = @min(offset, src.len);
    while (i < clamped_offset) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn set_module_compilation_message(
    sm: *DoeShaderModule,
    kind: CompilationMessageKind,
    message: []const u8,
    line: u32,
    column: u32,
) void {
    if (sm.compilation_message) |existing| {
        alloc.free(existing);
        sm.compilation_message = null;
    }
    sm.compilation_message = alloc.dupe(u8, message) catch null;
    sm.compilation_message_kind = kind;
    sm.compilation_message_line = line;
    sm.compilation_message_column = column;
}

fn set_module_info_from_diagnostic_directive(sm: *DoeShaderModule, wgsl: []const u8) void {
    const offset = std.mem.indexOf(u8, wgsl, "diagnostic") orelse return;
    const loc = offset_to_line_column(wgsl, offset);
    set_module_compilation_message(sm, .info, DIAGNOSTIC_DIRECTIVE_INFO, loc.line, loc.column);
}

fn set_module_warning_from_compiler_state(
    sm: *DoeShaderModule,
    fallback_message: []const u8,
) void {
    const detail = wgsl_compiler.lastErrorMessage();
    const line = wgsl_compiler.lastErrorLine();
    const column = wgsl_compiler.lastErrorColumn();
    const message = if (detail.len > 0) detail else fallback_message;
    set_module_compilation_message(sm, .warning, message, line, column);
}

pub fn ensureShaderBindings(sm: *DoeShaderModule) void {
    if (sm.bindings_ready) return;
    const wgsl = sm.wgsl_source orelse return;
    sm.bindings_ready = true;
    sm.binding_count = 0;
    var bind_meta: [native_shared.MAX_SHADER_BINDINGS]wgsl_compiler.BindingMeta = undefined;
    const bind_count = wgsl_compiler.extractBindings(alloc, wgsl, &bind_meta) catch |bind_err| blk: {
        std.log.warn("doe: createShaderModule: lazy binding extraction failed ({s}); proceeding with 0 bindings", .{@errorName(bind_err)});
        set_module_warning_from_compiler_state(sm, "binding extraction failed after successful shader compilation");
        break :blk 0;
    };
    for (0..bind_count) |i| {
        sm.bindings[i] = .{
            .group = bind_meta[i].group,
            .binding = bind_meta[i].binding,
            .kind = @intFromEnum(bind_meta[i].kind),
            .addr_space = @intFromEnum(bind_meta[i].addr_space),
            .access = @intFromEnum(bind_meta[i].access),
        };
    }
    sm.binding_count = @intCast(bind_count);
}
pub export fn doeNativeDeviceCreateShaderModule(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUShaderModuleDescriptor) callconv(.c) ?*anyopaque {
    clear_last_error();
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const d = desc orelse return null;
    const chain = d.nextInChain orelse return null;

    const result = switch (chain.sType) {
        abi_core.WGPUSType_ShaderSourceWGSL => createFromWGSL(dev, chain),
        abi_core.WGPUSType_ShaderSourceMSL => createFromMSL(dev, chain),
        abi_core.WGPUSType_ShaderSourceSPIRV => createFromSPIRV(chain),
        abi_core.WGPUSType_ShaderSourceHLSL => createFromHLSL(chain),
        else => blk: {
            set_last_error_stage_name("native_shader_create");
            set_last_error_kind("UnsupportedShaderFormat");
            set_last_error_fmt("unsupported shader source sType: 0x{x:0>8}", .{chain.sType});
            std.log.warn("doe: createShaderModule failed: unsupported sType 0x{x:0>8}", .{chain.sType});
            break :blk null;
        },
    };
    // Return a valid error-flagged module when compilation fails so Dawn's
    // wire server never gets null (which causes SIGSEGV in the GPU process).
    const handle = result orelse blk: {
        const err_sm = make(DoeShaderModule) orelse return null;
        err_sm.* = .{};
        const message = if (last_error_len > 0)
            last_error_buf[0..last_error_len]
        else
            "shader module creation failed";
        set_module_compilation_message(
            err_sm,
            .@"error",
            message,
            last_error_line,
            last_error_col,
        );
        break :blk toOpaque(err_sm);
    };
    label_store.set(handle, d.label.data, d.label.length);
    return handle;
}

pub export fn doeNativeDeviceCreateShaderModuleWgsl(dev_raw: ?*anyopaque, code_ptr: ?[*]const u8, code_len: usize) callconv(.c) ?*anyopaque {
    if (code_ptr == null) {
        clear_last_error();
        set_last_error_stage_name("native_shader_create");
        set_last_error_kind("InvalidInput");
        set_last_error("shader module creation failed: WGSL source pointer is null");
        return null;
    }
    var source = abi_pipeline.WGPUShaderSourceWGSL{
        .chain = .{ .next = null, .sType = abi_core.WGPUSType_ShaderSourceWGSL },
        .code = .{ .data = code_ptr, .length = code_len },
    };
    var desc = abi_pipeline.WGPUShaderModuleDescriptor{
        .nextInChain = &source.chain,
        .label = .{ .data = null, .length = 0 },
    };
    return doeNativeDeviceCreateShaderModule(dev_raw, &desc);
}

// ============================================================
// WGSL path (existing behavior, refactored into helper)
// ============================================================
fn createFromWGSL(dev: *DoeDevice, chain: *const abi_callback.WGPUChainedStruct) ?*anyopaque {
    const wgsl_chain: *const abi_pipeline.WGPUShaderSourceWGSL = @ptrCast(@alignCast(chain));
    const wgsl = resolveStringView(wgsl_chain.code) orelse return null;

    if (dev.backend == .vulkan) return createFromWGSLVulkan(dev, wgsl);

    const source_hash = hash_wgsl_source(wgsl);
    if (tryCreateCachedWgslShaderModule(wgsl, source_hash)) |cached_module| return cached_module;

    var cached_translation: ?shader_translation_cache.CachedTranslation = shader_translation_cache.lookupComputeTranslation(alloc, wgsl);
    var msl_buf: [wgsl_compiler.MAX_OUTPUT]u8 = undefined;
    var translation_info = wgsl_runtime_compile.TranslationInfo{};
    var msl_source: []const u8 = undefined;
    defer {
        if (cached_translation) |*cached| cached.deinit(alloc);
        translation_info.deinit(alloc);
    }
    if (cached_translation) |*cached| {
        translation_info = cached.info;
        cached.info = .{};
        msl_source = cached.msl;
    } else {
        var translation = wgsl_runtime_compile.translateToMslForComputeRuntime(
            alloc,
            wgsl,
            &msl_buf,
            null,
            0,
        ) catch |err| {
            set_last_error_stage(wgsl_compiler.lastErrorStage());
            set_last_error_kind(@errorName(err));
            capture_wgsl_error_location();
            const detail = wgsl_compiler.lastErrorMessage();
            if (detail.len > 0) {
                set_last_error_fmt("WGSL→MSL translation failed: {s}", .{detail});
            } else {
                set_last_error_fmt("WGSL→MSL translation failed: {s}", .{@errorName(err)});
            }
            std.log.warn("doe: createShaderModule failed: {s}", .{last_error_buf[0..last_error_len]});
            return null;
        };
        shader_translation_cache.storeComputeTranslation(
            alloc,
            wgsl,
            msl_buf[0..translation.len],
            &translation.info,
        );
        translation_info = translation.info;
        translation.info = .{};
        msl_source = msl_buf[0..translation.len];
    }

    var err_buf: [ERR_CAP]u8 = undefined;
    const lib = compileMslToLibrary(dev, msl_source.ptr, msl_source.len, &err_buf) orelse return null;

    const sm = make(DoeShaderModule) orelse {
        metal_bridge_release(lib);
        return null;
    };
    sm.* = .{ .mtl_library = lib };
    storeWgslShaderModuleCache(source_hash, lib, &translation_info);
    set_module_info_from_diagnostic_directive(sm, wgsl);
    sm.needs_sizes_buf = translation_info.needs_sizes_buf;
    sm.dispatch_preconditions = translation_info.dispatch_preconditions;
    translation_info.dispatch_preconditions = &.{};
    sm.wg_x = translation_info.workgroup_size[0];
    sm.wg_y = translation_info.workgroup_size[1];
    sm.wg_z = translation_info.workgroup_size[2];
    sm.wgsl_source = alloc.dupe(u8, wgsl) catch null;
    return toOpaque(sm);
}
// ============================================================
// Vulkan WGSL path — WGSL → SPIR-V, no Metal library
// ============================================================

fn createFromWGSLVulkan(dev: *DoeDevice, wgsl: []const u8) ?*anyopaque {
    _ = dev;
    const sm = make(DoeShaderModule) orelse return null;
    sm.* = .{};
    set_module_info_from_diagnostic_directive(sm, wgsl);
    sm.binding_count = 0;

    // Probe entry point stages to decide compute vs graphics compilation path.
    const vk_render = @import("doe_vulkan_render_native.zig");
    const has_graphics = vk_render.probe_has_graphics_entry_points(wgsl);

    if (has_graphics) {
        vk_render.vulkan_create_graphics_shader_module(sm, wgsl) catch |err| {
            set_last_error_stage_name("native_shader_create");
            set_last_error_kind(@errorName(err));
            set_last_error_fmt("Vulkan WGSL→SPIR-V graphics compilation failed: {s}", .{@errorName(err)});
            std.log.err("doe: createShaderModule (Vulkan graphics) failed: {s}", .{@errorName(err)});
            if (sm.vertex_spirv_data) |s| alloc.free(s);
            if (sm.fragment_spirv_data) |s| alloc.free(s);
            alloc.destroy(sm);
            return null;
        };
    } else {
        const vk_compute = @import("doe_vulkan_compute_native.zig");
        vk_compute.vulkan_create_shader_module(sm, wgsl) catch |err| {
            set_last_error_stage_name("native_shader_create");
            set_last_error_kind(@errorName(err));
            set_last_error_fmt("Vulkan WGSL→SPIR-V compilation failed: {s}", .{@errorName(err)});
            std.log.err("doe: createShaderModule (Vulkan) failed: {s}", .{@errorName(err)});
            if (sm.dispatch_preconditions.len > 0) alloc.free(sm.dispatch_preconditions);
            alloc.destroy(sm);
            return null;
        };
    }
    sm.wgsl_source = alloc.dupe(u8, wgsl) catch null;
    return toOpaque(sm);
}

// ============================================================
// MSL path — pre-translated Metal Shading Language source
// ============================================================

fn createFromMSL(dev: *DoeDevice, chain: *const abi_callback.WGPUChainedStruct) ?*anyopaque {
    const msl_chain: *const abi_pipeline.WGPUShaderSourceMSL = @ptrCast(@alignCast(chain));
    const msl_src = resolveStringView(msl_chain.code) orelse {
        set_last_error_stage_name("native_shader_create");
        set_last_error_kind("InvalidInput");
        set_last_error("pre-translated MSL source pointer is null");
        return null;
    };

    // Compile MSL → MTLLibrary directly (skip WGSL translation).
    var err_buf: [ERR_CAP]u8 = undefined;
    const lib = metal_bridge_device_new_library_msl(
        dev.mtl_device,
        msl_src.ptr,
        msl_src.len,
        &err_buf,
        ERR_CAP,
    ) orelse {
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        set_last_error_stage_name("native_compile");
        set_last_error_kind("MSLCompilationFailed");
        if (err_msg.len > 0) {
            set_last_error_fmt("pre-translated MSL compilation failed: {s}", .{err_msg});
            std.log.err("doe: createShaderModule (MSL) failed: {s}", .{err_msg});
        } else {
            set_last_error("pre-translated MSL compilation failed: MTLLibrary creation returned null");
            std.log.err("doe: createShaderModule (MSL) failed: MTLLibrary returned null", .{});
        }
        return null;
    };

    const sm = make(DoeShaderModule) orelse {
        metal_bridge_release(lib);
        return null;
    };
    sm.* = .{ .mtl_library = lib };
    // Binding metadata is unavailable from pre-translated MSL (degraded mode).
    sm.binding_count = 0;
    sm.needs_sizes_buf = false;
    sm.wg_x = normalizeWorkgroupDim(msl_chain.workgroup_size_x);
    sm.wg_y = normalizeWorkgroupDim(msl_chain.workgroup_size_y);
    sm.wg_z = normalizeWorkgroupDim(msl_chain.workgroup_size_z);
    return toOpaque(sm);
}

// ============================================================
// SPIR-V path — store binary for Vulkan pipeline creation
// ============================================================

fn createFromSPIRV(chain: *const abi_callback.WGPUChainedStruct) ?*anyopaque {
    const spirv_chain: *const abi_pipeline.WGPUShaderSourceSPIRV = @ptrCast(@alignCast(chain));

    if (spirv_chain.code_size == 0 or spirv_chain.code_size % 4 != 0) {
        set_last_error_stage_name("native_shader_create");
        set_last_error_kind("InvalidSPIRV");
        set_last_error("SPIR-V code_size must be a positive multiple of 4");
        return null;
    }

    const word_count = spirv_chain.code_size / 4;
    const spirv_copy = alloc.alloc(u32, word_count) catch {
        set_last_error_stage_name("native_shader_create");
        set_last_error_kind("OutOfMemory");
        set_last_error("failed to allocate SPIR-V storage");
        return null;
    };
    @memcpy(spirv_copy, spirv_chain.code[0..word_count]);

    const sm = make(DoeShaderModule) orelse {
        alloc.free(spirv_copy);
        return null;
    };
    sm.* = .{};
    sm.spirv_data = spirv_copy;
    sm.binding_count = 0;
    sm.needs_sizes_buf = false;
    sm.wg_x = normalizeWorkgroupDim(spirv_chain.workgroup_size_x);
    sm.wg_y = normalizeWorkgroupDim(spirv_chain.workgroup_size_y);
    sm.wg_z = normalizeWorkgroupDim(spirv_chain.workgroup_size_z);
    return toOpaque(sm);
}

// ============================================================
// HLSL path — store source for D3D12 DXC compilation
// ============================================================

fn createFromHLSL(chain: *const abi_callback.WGPUChainedStruct) ?*anyopaque {
    const hlsl_chain: *const abi_pipeline.WGPUShaderSourceHLSL = @ptrCast(@alignCast(chain));
    const hlsl_src = resolveStringView(hlsl_chain.code) orelse {
        set_last_error_stage_name("native_shader_create");
        set_last_error_kind("InvalidInput");
        set_last_error("HLSL source pointer is null");
        return null;
    };

    const hlsl_copy = alloc.alloc(u8, hlsl_src.len) catch {
        set_last_error_stage_name("native_shader_create");
        set_last_error_kind("OutOfMemory");
        set_last_error("failed to allocate HLSL storage");
        return null;
    };
    @memcpy(hlsl_copy, hlsl_src);

    const sm = make(DoeShaderModule) orelse {
        alloc.free(hlsl_copy);
        return null;
    };
    sm.* = .{};
    sm.hlsl_source = hlsl_copy;
    sm.binding_count = 0;
    sm.needs_sizes_buf = false;
    sm.wg_x = normalizeWorkgroupDim(hlsl_chain.workgroup_size_x);
    sm.wg_y = normalizeWorkgroupDim(hlsl_chain.workgroup_size_y);
    sm.wg_z = normalizeWorkgroupDim(hlsl_chain.workgroup_size_z);
    return toOpaque(sm);
}

// ============================================================
// Shared MSL compilation helper
// ============================================================

fn compileMslToLibrary(dev: *DoeDevice, msl_buf: [*]const u8, msl_len: usize, err_buf: *[ERR_CAP]u8) ?*anyopaque {
    return metal_bridge_device_new_library_msl(
        dev.mtl_device,
        msl_buf,
        msl_len,
        err_buf,
        ERR_CAP,
    ) orelse {
        const err_msg = std.mem.sliceTo(err_buf, 0);
        set_last_error_stage_name("native_compile");
        set_last_error_kind("MSLCompilationFailed");
        if (err_msg.len > 0) {
            set_last_error_fmt("MSL compilation failed: {s}", .{err_msg});
            std.log.warn("doe: createShaderModule failed: MSL compilation error: {s}", .{err_msg});
        } else {
            set_last_error("MSL compilation failed: MTLLibrary creation returned null");
            std.log.warn("doe: createShaderModule failed: MTLLibrary creation returned null", .{});
        }
        return null;
    };
}

pub export fn doeNativeShaderModuleRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeShaderModule, raw)) |sm| {
        if (!native_helpers.object_should_destroy(sm)) return;
        label_store.remove(raw);
        if (sm.mtl_library) |l| {
            if (!sm.mtl_library_borrowed) metal_bridge_release(l);
        }
        if (sm.dispatch_preconditions.len > 0) alloc.free(sm.dispatch_preconditions);
        if (sm.spirv_data) |s| alloc.free(s);
        if (sm.vertex_spirv_data) |s| alloc.free(s);
        if (sm.fragment_spirv_data) |s| alloc.free(s);
        if (sm.hlsl_source) |h| alloc.free(h);
        if (sm.wgsl_source) |w| alloc.free(w);
        if (sm.compilation_message) |message| alloc.free(message);
        alloc.destroy(sm);
    }
}

// ============================================================
// Compute Pipeline
// ============================================================

fn createComputePipelineVulkan(sm: *DoeShaderModule, layout: ?*DoePipelineLayout, entry_point: ?[]const u8) ?*anyopaque {
    const cp = make(DoeComputePipeline) orelse return null;
    cp.* = .{};
    if (layout) |pipeline_layout| {
        native_helpers.object_add_ref(DoePipelineLayout, toOpaque(pipeline_layout));
        cp.layout = pipeline_layout;
    }
    native_helpers.object_add_ref(DoeShaderModule, toOpaque(sm));
    cp.shader_module = sm;
    cp.wg_x = sm.wg_x;
    cp.wg_y = sm.wg_y;
    cp.wg_z = sm.wg_z;
    cp.needs_sizes_buf = sm.needs_sizes_buf;
    cp.dispatch_preconditions = alloc.dupe(wgsl_ir.DispatchPrecondition, sm.dispatch_preconditions) catch {
        alloc.destroy(cp);
        return null;
    };
    // Capture the descriptor's entry-point name as an owned,
    // null-terminated string so the Vulkan submit path can match
    // against the SPIR-V's OpEntryPoint. See DoeComputePipeline.vk_entry_point_owned.
    if (entry_point) |ep| {
        if (ep.len > 0) {
            cp.vk_entry_point_owned = alloc.dupeZ(u8, ep) catch {
                set_last_error_stage_name("native_compile");
                set_last_error_kind("OutOfMemory");
                set_last_error("Vulkan compute pipeline creation failed: OOM duplicating entry point name");
                if (cp.dispatch_preconditions.len > 0) alloc.free(cp.dispatch_preconditions);
                alloc.destroy(cp);
                return null;
            };
        }
    }
    const vk_compute = @import("doe_vulkan_compute_native.zig");
    vk_compute.vulkan_copy_pipeline_spirv(cp, sm) catch {
        set_last_error_stage_name("native_compile");
        set_last_error_kind("OutOfMemory");
        set_last_error("Vulkan compute pipeline creation failed: OOM duplicating SPIR-V");
        std.log.err("doe: createComputePipeline (Vulkan) failed: OOM duplicating SPIR-V", .{});
        if (cp.vk_entry_point_owned) |ep| alloc.free(ep);
        if (cp.dispatch_preconditions.len > 0) alloc.free(cp.dispatch_preconditions);
        alloc.destroy(cp);
        return null;
    };
    return toOpaque(cp);
}

fn stringViewSlice(view: abi_core.WGPUStringView) ?[]const u8 {
    const data = view.data orelse return null;
    const len = if (view.length == abi_core.WGPU_STRLEN)
        std.mem.len(@as([*:0]const u8, @ptrCast(data)))
    else
        view.length;
    if (len == 0) return null;
    return data[0..len];
}

// ============================================================
// Override constants — re-translate WGSL with overrides applied
// ============================================================

const MAX_OVERRIDE_ENTRIES: usize = 64;

/// Convert WGPUConstantEntry C ABI array to wgsl_ir.OverrideEntry slice for the compiler.
/// Returns null if any key pointer is invalid.
fn buildOverrideEntries(
    constants: [*]const abi_pipeline.WGPUConstantEntry,
    count: usize,
    out: *[MAX_OVERRIDE_ENTRIES]wgsl_ir.OverrideEntry,
) ?[]const wgsl_ir.OverrideEntry {
    if (count > MAX_OVERRIDE_ENTRIES) return null;
    for (0..count) |i| {
        const c = constants[i];
        const key_data = c.key.data orelse return null;
        const key_len = if (c.key.length == abi_core.WGPU_STRLEN)
            std.mem.len(@as([*:0]const u8, @ptrCast(key_data)))
        else
            c.key.length;
        out[i] = .{
            .key = key_data[0..key_len],
            .value = c.value,
        };
    }
    return out[0..count];
}

/// Re-translate WGSL source with override constants applied, compile to MTLLibrary.
/// Returns a new MTLLibrary handle (caller must release), or null on failure.
fn recompileWithOverrides(
    dev: *DoeDevice,
    sm: *DoeShaderModule,
    constants: [*]const abi_pipeline.WGPUConstantEntry,
    count: usize,
) ?*anyopaque {
    const wgsl = sm.wgsl_source orelse {
        set_last_error_stage_name("native_compile");
        set_last_error_kind("OverrideConstantsUnavailable");
        set_last_error("pipeline override constants require WGSL source (not pre-translated MSL/SPIR-V)");
        return null;
    };

    var entries: [MAX_OVERRIDE_ENTRIES]wgsl_ir.OverrideEntry = undefined;
    const override_slice = buildOverrideEntries(constants, count, &entries) orelse {
        set_last_error_stage_name("native_compile");
        set_last_error_kind("InvalidOverrideConstants");
        set_last_error("pipeline override constants: invalid key pointer or too many entries");
        return null;
    };

    var msl_buf: [wgsl_compiler.MAX_OUTPUT]u8 = undefined;
    var translation = wgsl_runtime_compile.translateToMslForComputeRuntime(
        alloc,
        wgsl,
        &msl_buf,
        override_slice.ptr,
        override_slice.len,
    ) catch |err| {
        set_last_error_stage(wgsl_compiler.lastErrorStage());
        set_last_error_kind(@errorName(err));
        capture_wgsl_error_location();
        const detail = wgsl_compiler.lastErrorMessage();
        if (detail.len > 0) {
            set_last_error_fmt("WGSL→MSL re-translation with overrides failed: {s}", .{detail});
        } else {
            set_last_error_fmt("WGSL→MSL re-translation with overrides failed: {s}", .{@errorName(err)});
        }
        return null;
    };
    defer translation.info.deinit(alloc);

    var err_buf: [ERR_CAP]u8 = undefined;
    return compileMslToLibrary(dev, &msl_buf, translation.len, &err_buf);
}

pub export fn doeNativeDeviceCreateComputePipeline(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUComputePipelineDescriptor) callconv(.c) ?*anyopaque {
    clear_last_error();
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const d = desc orelse return null;
    const sm = cast(DoeShaderModule, d.compute.module) orelse {
        set_last_error_stage_name("native_compile");
        set_last_error_kind("InvalidShaderModule");
        set_last_error("compute pipeline creation failed: shader module is null or invalid");
        std.log.warn("doe: createComputePipeline failed: shader module is null or invalid. " ++
            "Ensure createShaderModule succeeded (check stderr for WGSL translation errors).", .{});
        return null;
    };

    if (dev.backend == .vulkan) {
        // Resolve the entry-point name from the descriptor so the
        // Vulkan submit path can match against the SPIR-V's actual
        // OpEntryPoint. Null/empty descriptor → default to "main".
        const entry_slice = stringViewSlice(d.compute.entryPoint);
        const result = createComputePipelineVulkan(sm, cast(DoePipelineLayout, d.layout), entry_slice);
        if (result != null) label_store.set(result, d.label.data, d.label.length);
        return result;
    }

    // If override constants are provided, re-translate the WGSL with overrides applied.
    const has_overrides = d.compute.constantCount > 0 and d.compute.constants != null;
    var override_lib: ?*anyopaque = null;
    if (has_overrides) {
        override_lib = recompileWithOverrides(dev, sm, d.compute.constants.?, d.compute.constantCount);
        if (override_lib == null) return null;
    }
    const active_lib = override_lib orelse sm.mtl_library;

    // Map entry point name: WGSL "main" → MSL "main_kernel" (Metal forbids "main").
    var entry_owned: ?[:0]u8 = null;
    defer if (entry_owned) |owned| alloc.free(owned);
    const entry: [*:0]const u8 = blk: {
        if (stringViewSlice(d.compute.entryPoint)) |ep_slice| {
            if (std.mem.eql(u8, ep_slice, "main")) break :blk "main_kernel";
            entry_owned = alloc.dupeZ(u8, ep_slice) catch {
                if (override_lib) |ol| metal_bridge_release(ol);
                set_last_error_stage_name("native_compile");
                set_last_error_kind("OutOfMemory");
                set_last_error("compute pipeline creation failed: OOM duplicating entry point");
                return null;
            };
            break :blk entry_owned.?.ptr;
        }
        break :blk "main_kernel";
    };

    const func = metal_bridge_library_new_function(active_lib, entry) orelse {
        if (override_lib) |ol| metal_bridge_release(ol);
        set_last_error_stage_name("native_compile");
        set_last_error_kind("EntryPointNotFound");
        set_last_error_fmt("compute pipeline creation failed: entry point '{s}' not found", .{std.mem.span(entry)});
        std.log.err("doe: createComputePipeline failed: entry point '{s}' not found in shader module", .{std.mem.span(entry)});
        return null;
    };
    defer metal_bridge_release(func);

    var err_buf: [ERR_CAP]u8 = undefined;
    const pso = blk: {
        if (package_metal_pipeline_cache.get(dev)) |cache| {
            if (cache.compile_or_serve_compute(func)) |cached_pso| break :blk cached_pso;
        }
        break :blk metal_bridge_device_new_compute_pipeline(dev.mtl_device, func, &err_buf, ERR_CAP);
    } orelse {
        if (override_lib) |ol| metal_bridge_release(ol);
        const err_msg = std.mem.sliceTo(&err_buf, 0);
        set_last_error_stage_name("native_compile");
        set_last_error_kind("ComputePipelineCreationFailed");
        if (err_msg.len > 0) {
            set_last_error_fmt("compute pipeline creation failed: {s}", .{err_msg});
            std.log.err("doe: createComputePipeline failed: {s}", .{err_msg});
        } else {
            set_last_error("compute pipeline creation failed: MTLComputePipelineState creation returned null");
            std.log.err("doe: createComputePipeline failed: MTLComputePipelineState creation returned null", .{});
        }
        return null;
    };

    // Override library is no longer needed after PSO creation — release it.
    if (override_lib) |ol| metal_bridge_release(ol);

    const cp = make(DoeComputePipeline) orelse {
        metal_bridge_release(pso);
        return null;
    };
    cp.* = .{ .mtl_pso = pso };
    if (cast(DoePipelineLayout, d.layout)) |pipeline_layout| {
        native_helpers.object_add_ref(DoePipelineLayout, toOpaque(pipeline_layout));
        cp.layout = pipeline_layout;
    }
    native_helpers.object_add_ref(DoeShaderModule, toOpaque(sm));
    cp.shader_module = sm;
    cp.wg_x = sm.wg_x;
    cp.wg_y = sm.wg_y;
    cp.wg_z = sm.wg_z;
    cp.needs_sizes_buf = sm.needs_sizes_buf;
    cp.dispatch_preconditions = alloc.dupe(wgsl_ir.DispatchPrecondition, sm.dispatch_preconditions) catch {
        metal_bridge_release(pso);
        alloc.destroy(cp);
        return null;
    };
    const result = toOpaque(cp);
    label_store.set(result, d.label.data, d.label.length);
    return result;
}

pub export fn doeNativeDeviceCreateComputePipelineMain(dev_raw: ?*anyopaque, shader_raw: ?*anyopaque, layout_raw: ?*anyopaque) callconv(.c) ?*anyopaque {
    const main_entry = "main";
    var desc = abi_pipeline.WGPUComputePipelineDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .layout = layout_raw,
        .compute = .{
            .nextInChain = null,
            .module = shader_raw,
            .entryPoint = .{ .data = main_entry.ptr, .length = main_entry.len },
            .constantCount = 0,
            .constants = null,
        },
    };
    return doeNativeDeviceCreateComputePipeline(dev_raw, &desc);
}

pub export fn doeNativeComputePipelineRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeComputePipeline, raw)) |p| {
        label_store.remove(raw);
        if (p.mtl_pso) |pso| metal_bridge_release(pso);
        if (p.dispatch_preconditions.len > 0) alloc.free(p.dispatch_preconditions);
        if (p.layout) |layout| bind_group.doeNativePipelineLayoutRelease(toOpaque(layout));
        if (p.shader_module) |shader_module| doeNativeShaderModuleRelease(toOpaque(shader_module));
        const vk_compute = @import("doe_vulkan_compute_native.zig");
        vk_compute.vulkan_release_compute_pipeline(p);
        alloc.destroy(p);
    }
}
