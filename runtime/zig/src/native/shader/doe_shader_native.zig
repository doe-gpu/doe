// doe_shader_native.zig — Shader module and compute pipeline creation for Doe native Metal backend.
// Sharded from doe_wgpu_native.zig: WGSL→MSL translation, MTLLibrary/MTLComputePipelineState creation.

const std = @import("std");
const abi_core = @import("../../core/abi/wgpu_core_base_types.zig");
const abi_callback = @import("../../core/abi/wgpu_callback_descriptor_types.zig");
const abi_pipeline = @import("../../core/abi/wgpu_pipeline_descriptor_types.zig");
const wgsl_analysis = @import("../../compiler/wgsl/pipeline/analysis.zig");
const wgsl_bindings = @import("../../compiler/wgsl/pipeline/binding_reflection.zig");
const msl_translation = @import("../../compiler/wgsl/pipeline/translate_msl.zig");
const wgsl_ir = @import("../../compiler/wgsl/ir/ir.zig");
const wgsl_runtime_compile = @import("../../compiler/wgsl/runtime/runtime_compute_translation.zig");
const shader_translation_cache = @import("doe_shader_translation_cache.zig");
const shader_binding_reflection = @import("shader_binding_reflection.zig");
const package_metal_pipeline_cache = @import("../cache/doe_package_metal_pipeline_cache.zig");
const native_types = @import("../support/doe_native_object_types.zig");
const native_shared = @import("../support/doe_native_shared_types.zig");
const native_helpers = @import("../support/doe_native_object_helpers.zig");
const bind_group = @import("../resource/doe_bind_group_native.zig");
const resource_ops = @import("../../backend/dropin_resource_ops.zig");
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
const ShaderDiagnostic = @import("shader_diagnostic.zig").ShaderDiagnostic;
threadlocal var last_diagnostic = ShaderDiagnostic{};
const DIAGNOSTIC_DIRECTIVE_INFO: []const u8 =
    "WGSL diagnostic directives are parsed on this path and currently reported as advisory compilation info only.";
fn tryCreateCachedWgslShaderModule(dev: *DoeDevice, wgsl: []const u8) error{OutOfMemory}!?*anyopaque {
    var cached = (try dev.metal_libraries.lookup(alloc, wgsl, shader_translation_cache.metalLibraryConfiguration())) orelse return null;
    var transferred = false;
    defer if (!transferred) cached.deinit(alloc, dev.metal_libraries.ops);
    const sm = make(DoeShaderModule) orelse return error.OutOfMemory;
    errdefer alloc.destroy(sm);
    const source = try alloc.dupe(u8, wgsl);
    sm.* = .{ .mtl_library = cached.library, .wgsl_source = source, .wg_x = cached.info.workgroup_size[0], .wg_y = cached.info.workgroup_size[1], .wg_z = cached.info.workgroup_size[2], .needs_sizes_buf = cached.info.needs_sizes_buf, .dispatch_preconditions = cached.info.dispatch_preconditions, .texture_dispatch_preconditions = cached.info.texture_dispatch_preconditions };
    transferred = true;
    set_module_info_from_diagnostic_directive(sm, wgsl);
    return toOpaque(sm);
}

pub export fn doeNativeCopyLastErrorMessage(out_ptr: ?[*]u8, out_len: usize) callconv(.c) usize {
    if (out_ptr == null or out_len == 0 or last_diagnostic.last_error_len == 0) return last_diagnostic.last_error_len;
    const dst = out_ptr.?[0..out_len];
    const copy_len = @min(last_diagnostic.last_error_len, out_len - 1);
    @memcpy(dst[0..copy_len], last_diagnostic.last_error_buf[0..copy_len]);
    dst[copy_len] = 0;
    return last_diagnostic.last_error_len;
}

pub export fn doeNativeCopyLastErrorStage(out_ptr: ?[*]u8, out_len: usize) callconv(.c) usize {
    if (out_ptr == null or out_len == 0 or last_diagnostic.last_error_stage_len == 0) return last_diagnostic.last_error_stage_len;
    const dst = out_ptr.?[0..out_len];
    const copy_len = @min(last_diagnostic.last_error_stage_len, out_len - 1);
    @memcpy(dst[0..copy_len], last_diagnostic.last_error_stage_buf[0..copy_len]);
    dst[copy_len] = 0;
    return last_diagnostic.last_error_stage_len;
}

pub export fn doeNativeCopyLastErrorKind(out_ptr: ?[*]u8, out_len: usize) callconv(.c) usize {
    if (out_ptr == null or out_len == 0 or last_diagnostic.last_error_kind_len == 0) return last_diagnostic.last_error_kind_len;
    const dst = out_ptr.?[0..out_len];
    const copy_len = @min(last_diagnostic.last_error_kind_len, out_len - 1);
    @memcpy(dst[0..copy_len], last_diagnostic.last_error_kind_buf[0..copy_len]);
    dst[copy_len] = 0;
    return last_diagnostic.last_error_kind_len;
}

pub export fn doeNativeGetLastErrorLine() callconv(.c) u32 {
    return last_diagnostic.last_error_line;
}

pub export fn doeNativeGetLastErrorColumn() callconv(.c) u32 {
    return last_diagnostic.last_error_col;
}

fn doeNativeCheckShaderSourceOwned(code_ptr: ?[*]const u8, code_len: usize, diagnostic: *ShaderDiagnostic) u32 {
    diagnostic.clear_last_error();
    const ptr = code_ptr orelse {
        diagnostic.set_last_error_stage_name("native_check");
        diagnostic.set_last_error_kind("InvalidInput");
        diagnostic.set_last_error("shader check failed: WGSL source pointer is null");
        return 0;
    };
    const wgsl = ptr[0..code_len];
    var msl_buf: [msl_translation.MAX_OUTPUT]u8 = undefined;
    _ = msl_translation.translateToMslWithDiagnostic(alloc, wgsl, &msl_buf, &diagnostic.compiler) catch |err| {
        diagnostic.set_last_error_stage(diagnostic.compiler.lastErrorStage());
        diagnostic.set_last_error_kind(@errorName(err));
        diagnostic.capture_wgsl_error_location();
        const detail = diagnostic.compiler.lastErrorMessage();
        if (detail.len > 0) {
            diagnostic.set_last_error(detail);
        } else {
            diagnostic.set_last_error_fmt("{s}: {s}", .{ @tagName(diagnostic.compiler.lastErrorStage()), @errorName(err) });
        }
        return 0;
    };
    return 1;
}

fn doeNativeShaderModuleGetBindingsOwned(raw: ?*anyopaque, out_ptr: ?[*]native_shared.BindingInfo, out_len: usize, diagnostic: *ShaderDiagnostic) usize {
    const sm = cast(DoeShaderModule, raw) orelse {
        diagnostic.capture_compile_error(error.InvalidShaderModule, "reflection", "expected a live shader module");
        return std.math.maxInt(usize);
    };
    ensureShaderBindings(sm) catch |err| {
        diagnostic.capture_compile_error(err, "reflection", "shader binding extraction failed");
        return std.math.maxInt(usize);
    };
    const count: usize = sm.binding_count;
    if (out_ptr) |out| {
        const copy_len = @min(count, out_len);
        @memcpy(out[0..copy_len], sm.bindings[0..copy_len]);
    }
    return count;
}

fn doeNativeShaderModuleGetBindingsForEntryPointOwned(raw: ?*anyopaque, entry_ptr: ?[*]const u8, entry_len: usize, out_ptr: ?[*]native_shared.BindingInfo, out_len: usize, diagnostic: *ShaderDiagnostic) usize {
    const sm = cast(DoeShaderModule, raw) orelse {
        diagnostic.capture_compile_error(error.InvalidShaderModule, "reflection", "expected a live shader module");
        return std.math.maxInt(usize);
    };
    const wgsl = sm.wgsl_source orelse {
        diagnostic.capture_compile_error(error.UnsupportedWgsl, "reflection", "WGSL source is unavailable for reflection");
        return std.math.maxInt(usize);
    };
    const entry_point = (entry_ptr orelse {
        diagnostic.capture_compile_error(error.UnknownIdentifier, "reflection", "expected an entry point name");
        return std.math.maxInt(usize);
    })[0..entry_len];
    var metadata: [native_shared.MAX_SHADER_BINDINGS]wgsl_bindings.BindingMeta = undefined;
    const count = wgsl_bindings.extractBindingsForEntryPointWithDiagnostic(alloc, wgsl, entry_point, &metadata, &diagnostic.compiler) catch |err| {
        diagnostic.capture_compile_error(err, "reflection", "entry point binding extraction failed");
        return std.math.maxInt(usize);
    };
    if (out_ptr) |out| for (metadata[0..@min(count, out_len)], 0..) |binding, index| {
        out[index] = .{
            .group = binding.group,
            .binding = binding.binding,
            .kind = @intFromEnum(binding.kind),
            .addr_space = @intFromEnum(binding.addr_space),
            .access = @intFromEnum(binding.access),
        };
    };
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

const set_module_compilation_message = shader_binding_reflection.setCompilationMessage;

fn set_module_info_from_diagnostic_directive(sm: *DoeShaderModule, wgsl: []const u8) void {
    const offset = std.mem.indexOf(u8, wgsl, "diagnostic") orelse return;
    const loc = offset_to_line_column(wgsl, offset);
    set_module_compilation_message(sm, .info, DIAGNOSTIC_DIRECTIVE_INFO, loc.line, loc.column);
}

pub const ensureShaderBindings = shader_binding_reflection.ensureShaderBindings;
fn doeNativeDeviceCreateShaderModuleOwned(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUShaderModuleDescriptor, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    diagnostic.clear_last_error();
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const d = desc orelse return null;
    if (d.nextInChain == null) return null;
    const chain: *const abi_callback.WGPUChainedStruct = @ptrCast(d.nextInChain);

    const result = switch (chain.sType) {
        abi_core.WGPUSType_ShaderSourceWGSL => createFromWGSLOwned(dev, chain, diagnostic),
        abi_core.WGPUSType_ShaderSourceMSL => createFromMSLOwned(dev, chain, diagnostic),
        abi_core.WGPUSType_ShaderSourceSPIRV => createFromSPIRVOwned(chain, diagnostic),
        abi_core.WGPUSType_ShaderSourceHLSL => createFromHLSLOwned(chain, diagnostic),
        else => blk: {
            diagnostic.set_last_error_stage_name("native_shader_create");
            diagnostic.set_last_error_kind("UnsupportedShaderFormat");
            diagnostic.set_last_error_fmt("unsupported shader source sType: 0x{x:0>8}", .{chain.sType});
            std.log.warn("doe: createShaderModule failed: unsupported sType 0x{x:0>8}", .{chain.sType});
            break :blk null;
        },
    };
    // Return a valid error-flagged module when compilation fails so Dawn's
    // wire server never gets null (which causes SIGSEGV in the GPU process).
    const handle = result orelse blk: {
        const err_sm = make(DoeShaderModule) orelse return null;
        err_sm.* = .{};
        const message = if (diagnostic.last_error_len > 0)
            diagnostic.last_error_buf[0..diagnostic.last_error_len]
        else
            "shader module creation failed";
        set_module_compilation_message(
            err_sm,
            .@"error",
            message,
            diagnostic.last_error_line,
            diagnostic.last_error_col,
        );
        break :blk toOpaque(err_sm);
    };
    label_store.set(handle, d.label.data, d.label.length);
    return handle;
}

fn doeNativeDeviceCreateShaderModuleWgslOwned(dev_raw: ?*anyopaque, code_ptr: ?[*]const u8, code_len: usize, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    if (code_ptr == null) {
        diagnostic.clear_last_error();
        diagnostic.set_last_error_stage_name("native_shader_create");
        diagnostic.set_last_error_kind("InvalidInput");
        diagnostic.set_last_error("shader module creation failed: WGSL source pointer is null");
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
    return doeNativeDeviceCreateShaderModuleOwned(dev_raw, &desc, diagnostic);
}

// ============================================================
// WGSL path (existing behavior, refactored into helper)
// ============================================================
fn createFromWGSLOwned(dev: *DoeDevice, chain: *const abi_callback.WGPUChainedStruct, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    const wgsl_chain: *const abi_pipeline.WGPUShaderSourceWGSL = @ptrCast(@alignCast(chain));
    const wgsl = resolveStringView(wgsl_chain.code) orelse return null;

    if (dev.backend == .vulkan) return createFromWGSLVulkanOwned(dev, wgsl, diagnostic);

    if (tryCreateCachedWgslShaderModule(dev, wgsl) catch |err| {
        diagnostic.capture_compile_error(err, "native_shader_create", "retaining cached Metal shader failed");
        return null;
    }) |cached_module| return cached_module;
    const source = retainWgslSourceOwned(wgsl, diagnostic) orelse return null;
    var source_transferred = false;
    defer if (!source_transferred) alloc.free(source);

    var cached_translation: ?shader_translation_cache.CachedTranslation = shader_translation_cache.lookupComputeTranslation(alloc, wgsl);
    var msl_buf: [msl_translation.MAX_OUTPUT]u8 = undefined;
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
        var translation = wgsl_runtime_compile.translateToMslForComputeRuntimeWithDiagnostic(alloc, wgsl, &msl_buf, null, 0, &diagnostic.compiler) catch |err| {
            diagnostic.set_last_error_stage(diagnostic.compiler.lastErrorStage());
            diagnostic.set_last_error_kind(@errorName(err));
            diagnostic.capture_wgsl_error_location();
            const detail = diagnostic.compiler.lastErrorMessage();
            if (detail.len > 0) {
                diagnostic.set_last_error_fmt("WGSL→MSL translation failed: {s}", .{detail});
            } else {
                diagnostic.set_last_error_fmt("WGSL→MSL translation failed: {s}", .{@errorName(err)});
            }
            std.log.warn("doe: createShaderModule failed: {s}", .{diagnostic.last_error_buf[0..diagnostic.last_error_len]});
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
    const lib = compileMslToLibraryOwned(dev, msl_source.ptr, msl_source.len, &err_buf, diagnostic) orelse return null;

    const sm = make(DoeShaderModule) orelse {
        metal_bridge_release(lib);
        return null;
    };
    sm.* = .{ .mtl_library = lib };
    dev.metal_libraries.insert(alloc, wgsl, shader_translation_cache.metalLibraryConfiguration(), lib, &translation_info) catch |err| {
        doeNativeShaderModuleRelease(toOpaque(sm));
        diagnostic.capture_compile_error(err, "native_shader_create", "retaining Metal library cache entry failed");
        return null;
    };
    set_module_info_from_diagnostic_directive(sm, wgsl);
    sm.needs_sizes_buf = translation_info.needs_sizes_buf;
    sm.dispatch_preconditions = translation_info.dispatch_preconditions;
    translation_info.dispatch_preconditions = &.{};
    sm.texture_dispatch_preconditions = translation_info.texture_dispatch_preconditions;
    translation_info.texture_dispatch_preconditions = &.{};
    sm.wg_x = translation_info.workgroup_size[0];
    sm.wg_y = translation_info.workgroup_size[1];
    sm.wg_z = translation_info.workgroup_size[2];
    sm.wgsl_source = source;
    source_transferred = true;
    return toOpaque(sm);
}
// ============================================================
// Vulkan WGSL path — WGSL → SPIR-V, no Metal library
// ============================================================

fn createFromWGSLVulkanOwned(dev: *DoeDevice, wgsl: []const u8, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    _ = dev;
    const sm = make(DoeShaderModule) orelse return null;
    sm.* = .{};
    var complete = false;
    defer if (!complete) doeNativeShaderModuleRelease(toOpaque(sm));
    sm.wgsl_source = retainWgslSourceOwned(wgsl, diagnostic) orelse return null;
    set_module_info_from_diagnostic_directive(sm, wgsl);
    sm.binding_count = 0;

    // Probe entry point stages to decide compute vs graphics compilation path.
    const vk_render = @import("../vulkan/vulkan_render_native.zig");
    const has_graphics = vk_render.probe_has_graphics_entry_points(wgsl);

    if (has_graphics) {
        vk_render.vulkan_create_graphics_shader_moduleWithDiagnostic(sm, wgsl, &diagnostic.compiler) catch |err| {
            diagnostic.capture_compile_error(err, "native_shader_create", "Vulkan WGSL→SPIR-V graphics compilation failed");
            return null;
        };
    } else {
        const vk_compute = @import("../vulkan/vulkan_compute_native.zig");
        vk_compute.vulkan_create_shader_moduleWithDiagnostic(sm, wgsl, &diagnostic.compiler) catch |err| {
            diagnostic.capture_compile_error(err, "native_shader_create", "Vulkan WGSL→SPIR-V compilation failed");
            return null;
        };
    }
    complete = true;
    return toOpaque(sm);
}

// ============================================================
// MSL path — pre-translated Metal Shading Language source
// ============================================================

fn createFromMSLOwned(dev: *DoeDevice, chain: *const abi_callback.WGPUChainedStruct, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    const msl_chain: *const abi_pipeline.WGPUShaderSourceMSL = @ptrCast(@alignCast(chain));
    const msl_src = resolveStringView(msl_chain.code) orelse {
        diagnostic.set_last_error_stage_name("native_shader_create");
        diagnostic.set_last_error_kind("InvalidInput");
        diagnostic.set_last_error("pre-translated MSL source pointer is null");
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
        diagnostic.set_last_error_stage_name("native_compile");
        diagnostic.set_last_error_kind("MSLCompilationFailed");
        if (err_msg.len > 0) {
            diagnostic.set_last_error_fmt("pre-translated MSL compilation failed: {s}", .{err_msg});
            std.log.err("doe: createShaderModule (MSL) failed: {s}", .{err_msg});
        } else {
            diagnostic.set_last_error("pre-translated MSL compilation failed: MTLLibrary creation returned null");
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

fn createFromSPIRVOwned(chain: *const abi_callback.WGPUChainedStruct, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    const spirv_chain: *const abi_pipeline.WGPUShaderSourceSPIRV = @ptrCast(@alignCast(chain));

    if (spirv_chain.codeSize == 0 or spirv_chain.code == null) {
        diagnostic.set_last_error_stage_name("native_shader_create");
        diagnostic.set_last_error_kind("InvalidSPIRV");
        diagnostic.set_last_error("SPIR-V codeSize and code must describe at least one word");
        return null;
    }

    const word_count = spirv_chain.codeSize;
    const spirv_copy = alloc.alloc(u32, word_count) catch {
        diagnostic.set_last_error_stage_name("native_shader_create");
        diagnostic.set_last_error_kind("OutOfMemory");
        diagnostic.set_last_error("failed to allocate SPIR-V storage");
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
    sm.wg_x = 1;
    sm.wg_y = 1;
    sm.wg_z = 1;
    return toOpaque(sm);
}

// ============================================================
// HLSL path — store source for D3D12 DXC compilation
// ============================================================

fn createFromHLSLOwned(chain: *const abi_callback.WGPUChainedStruct, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    const hlsl_chain: *const abi_pipeline.WGPUShaderSourceHLSL = @ptrCast(@alignCast(chain));
    const hlsl_src = resolveStringView(hlsl_chain.code) orelse {
        diagnostic.set_last_error_stage_name("native_shader_create");
        diagnostic.set_last_error_kind("InvalidInput");
        diagnostic.set_last_error("HLSL source pointer is null");
        return null;
    };

    const hlsl_copy = alloc.alloc(u8, hlsl_src.len) catch {
        diagnostic.set_last_error_stage_name("native_shader_create");
        diagnostic.set_last_error_kind("OutOfMemory");
        diagnostic.set_last_error("failed to allocate HLSL storage");
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

fn compileMslToLibraryOwned(dev: *DoeDevice, msl_buf: [*]const u8, msl_len: usize, err_buf: *[ERR_CAP]u8, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    return metal_bridge_device_new_library_msl(
        dev.mtl_device,
        msl_buf,
        msl_len,
        err_buf,
        ERR_CAP,
    ) orelse {
        const err_msg = std.mem.sliceTo(err_buf, 0);
        diagnostic.set_last_error_stage_name("native_compile");
        diagnostic.set_last_error_kind("MSLCompilationFailed");
        if (err_msg.len > 0) {
            diagnostic.set_last_error_fmt("MSL compilation failed: {s}", .{err_msg});
            std.log.warn("doe: createShaderModule failed: MSL compilation error: {s}", .{err_msg});
        } else {
            diagnostic.set_last_error("MSL compilation failed: MTLLibrary creation returned null");
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
        if (sm.texture_dispatch_preconditions.len > 0) alloc.free(sm.texture_dispatch_preconditions);
        if (sm.spirv_data) |s| alloc.free(s);
        if (sm.vertex_spirv_data) |s| alloc.free(s);
        if (sm.fragment_spirv_data) |s| alloc.free(s);
        if (sm.hlsl_source) |h| alloc.free(h);
        if (sm.wgsl_source) |w| alloc.free(w);
        alloc.destroy(sm);
    }
}

// ============================================================
// Compute Pipeline
// ============================================================

fn createComputePipelineVulkanOwned(sm: *DoeShaderModule, layout: ?*DoePipelineLayout, entry_point: ?[]const u8, overrides: []const wgsl_ir.OverrideEntry, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    const cp = make(DoeComputePipeline) orelse return null;
    cp.* = .{};
    if (layout) |pipeline_layout| {
        cp.layout = pipeline_layout;
    }
    cp.shader_module = sm;
    cp.wg_x = sm.wg_x;
    cp.wg_y = sm.wg_y;
    cp.wg_z = sm.wg_z;
    cp.needs_sizes_buf = sm.needs_sizes_buf;
    if (overrides.len == 0) {
        cp.dispatch_preconditions = if (sm.dispatch_preconditions.len == 0)
            &.{}
        else
            alloc.dupe(wgsl_ir.DispatchPrecondition, sm.dispatch_preconditions) catch {
                alloc.destroy(cp);
                return null;
            };
        cp.texture_dispatch_preconditions = if (sm.texture_dispatch_preconditions.len == 0)
            &.{}
        else
            alloc.dupe(wgsl_ir.TextureDispatchPrecondition, sm.texture_dispatch_preconditions) catch {
                if (cp.dispatch_preconditions.len > 0) alloc.free(cp.dispatch_preconditions);
                alloc.destroy(cp);
                return null;
            };
    }
    // Capture the descriptor's entry-point name as an owned,
    // null-terminated string so the Vulkan submit path can match
    // against the SPIR-V's OpEntryPoint. See DoeComputePipeline.vk_entry_point_owned.
    if (entry_point) |ep| {
        if (ep.len > 0) {
            cp.vk_entry_point_owned = alloc.dupeZ(u8, ep) catch {
                diagnostic.set_last_error_stage_name("native_compile");
                diagnostic.set_last_error_kind("OutOfMemory");
                diagnostic.set_last_error("Vulkan compute pipeline creation failed: OOM duplicating entry point name");
                if (cp.dispatch_preconditions.len > 0) alloc.free(cp.dispatch_preconditions);
                if (cp.texture_dispatch_preconditions.len > 0) alloc.free(cp.texture_dispatch_preconditions);
                alloc.destroy(cp);
                return null;
            };
        }
    }
    const vk_compute = @import("../vulkan/vulkan_compute_native.zig");
    const compile_result = if (overrides.len > 0)
        vk_compute.vulkan_compile_pipeline_spirv_with_overridesWithDiagnostic(cp, sm, overrides, &diagnostic.compiler)
    else
        vk_compute.vulkan_copy_pipeline_spirvWithDiagnostic(cp, sm, &diagnostic.compiler);
    compile_result catch |err| {
        diagnostic.capture_compile_error(err, "native_compile", "Vulkan compute pipeline creation failed");
        if (cp.dispatch_preconditions.len > 0) alloc.free(cp.dispatch_preconditions);
        if (cp.texture_dispatch_preconditions.len > 0) alloc.free(cp.texture_dispatch_preconditions);
        vk_compute.vulkan_release_compute_pipeline(cp);
        alloc.destroy(cp);
        return null;
    };
    if (layout) |pipeline_layout| native_helpers.object_add_ref(DoePipelineLayout, toOpaque(pipeline_layout));
    native_helpers.object_add_ref(DoeShaderModule, toOpaque(sm));
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
fn recompileWithOverridesOwned(dev: *DoeDevice, sm: *DoeShaderModule, constants: [*]const abi_pipeline.WGPUConstantEntry, count: usize, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    const wgsl = sm.wgsl_source orelse {
        diagnostic.set_last_error_stage_name("native_compile");
        diagnostic.set_last_error_kind("OverrideConstantsUnavailable");
        diagnostic.set_last_error("pipeline override constants require WGSL source (not pre-translated MSL/SPIR-V)");
        return null;
    };

    var entries: [MAX_OVERRIDE_ENTRIES]wgsl_ir.OverrideEntry = undefined;
    const override_slice = buildOverrideEntries(constants, count, &entries) orelse {
        diagnostic.set_last_error_stage_name("native_compile");
        diagnostic.set_last_error_kind("InvalidOverrideConstants");
        diagnostic.set_last_error("pipeline override constants: invalid key pointer or too many entries");
        return null;
    };

    var msl_buf: [msl_translation.MAX_OUTPUT]u8 = undefined;
    var translation = wgsl_runtime_compile.translateToMslForComputeRuntimeWithDiagnostic(alloc, wgsl, &msl_buf, override_slice.ptr, override_slice.len, &diagnostic.compiler) catch |err| {
        diagnostic.set_last_error_stage(diagnostic.compiler.lastErrorStage());
        diagnostic.set_last_error_kind(@errorName(err));
        diagnostic.capture_wgsl_error_location();
        const detail = diagnostic.compiler.lastErrorMessage();
        if (detail.len > 0) {
            diagnostic.set_last_error_fmt("WGSL→MSL re-translation with overrides failed: {s}", .{detail});
        } else {
            diagnostic.set_last_error_fmt("WGSL→MSL re-translation with overrides failed: {s}", .{@errorName(err)});
        }
        return null;
    };
    defer translation.info.deinit(alloc);

    var err_buf: [ERR_CAP]u8 = undefined;
    return compileMslToLibraryOwned(dev, &msl_buf, translation.len, &err_buf, diagnostic);
}

fn doeNativeDeviceCreateComputePipelineOwned(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUComputePipelineDescriptor, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    diagnostic.clear_last_error();
    const dev = cast(DoeDevice, dev_raw) orelse return null;
    const d = desc orelse return null;
    const sm = cast(DoeShaderModule, d.compute.module) orelse {
        diagnostic.set_last_error_stage_name("native_compile");
        diagnostic.set_last_error_kind("InvalidShaderModule");
        diagnostic.set_last_error("compute pipeline creation failed: shader module is null or invalid");
        std.log.warn("doe: createComputePipeline failed: shader module is null or invalid. " ++
            "Ensure createShaderModule succeeded (check stderr for WGSL translation errors).", .{});
        return null;
    };

    if (sm.compilation_message_kind == .@"error") {
        diagnostic.set_last_error_stage_name("native_compile");
        diagnostic.set_last_error_kind("InvalidShaderModule");
        if (sm.compilation_message) |message| {
            diagnostic.set_last_error_fmt("compute pipeline creation rejected invalid shader module: {s}", .{message});
        } else {
            diagnostic.set_last_error("compute pipeline creation rejected invalid shader module");
        }
        return null;
    }
    if (sm.wgsl_source != null) ensureShaderBindings(sm) catch |err| {
        diagnostic.capture_compile_error(err, "reflection", "compute pipeline binding extraction failed");
        return null;
    };

    var entries: [MAX_OVERRIDE_ENTRIES]wgsl_ir.OverrideEntry = undefined;
    const override_slice = if (d.compute.constantCount > 0 and d.compute.constants != null)
        buildOverrideEntries(d.compute.constants.?, d.compute.constantCount, &entries) orelse {
            diagnostic.set_last_error_stage_name("native_compile");
            diagnostic.set_last_error_kind("InvalidOverrideConstants");
            diagnostic.set_last_error("pipeline override constants: invalid key pointer or too many entries");
            return null;
        }
    else
        entries[0..0];

    if (dev.backend == .vulkan) {
        // Resolve the entry-point name from the descriptor so the
        // Vulkan submit path can match against the SPIR-V's actual
        // OpEntryPoint. Null/empty descriptor → default to "main".
        const entry_slice = stringViewSlice(d.compute.entryPoint);
        const result = createComputePipelineVulkanOwned(sm, cast(DoePipelineLayout, d.layout), entry_slice, override_slice, diagnostic);
        if (result != null) label_store.set(result, d.label.data, d.label.length);
        return result;
    }

    // If override constants are provided, re-translate the WGSL with overrides applied.
    const has_overrides = override_slice.len > 0;
    var override_lib: ?*anyopaque = null;
    if (has_overrides) {
        override_lib = recompileWithOverridesOwned(dev, sm, d.compute.constants.?, d.compute.constantCount, diagnostic);
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
                diagnostic.set_last_error_stage_name("native_compile");
                diagnostic.set_last_error_kind("OutOfMemory");
                diagnostic.set_last_error("compute pipeline creation failed: OOM duplicating entry point");
                return null;
            };
            break :blk entry_owned.?.ptr;
        }
        break :blk "main_kernel";
    };

    const func = metal_bridge_library_new_function(active_lib, entry) orelse {
        if (override_lib) |ol| metal_bridge_release(ol);
        diagnostic.set_last_error_stage_name("native_compile");
        diagnostic.set_last_error_kind("EntryPointNotFound");
        diagnostic.set_last_error_fmt("compute pipeline creation failed: entry point '{s}' not found", .{std.mem.span(entry)});
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
        diagnostic.set_last_error_stage_name("native_compile");
        diagnostic.set_last_error_kind("ComputePipelineCreationFailed");
        if (err_msg.len > 0) {
            diagnostic.set_last_error_fmt("compute pipeline creation failed: {s}", .{err_msg});
            std.log.err("doe: createComputePipeline failed: {s}", .{err_msg});
        } else {
            diagnostic.set_last_error("compute pipeline creation failed: MTLComputePipelineState creation returned null");
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
    cp.texture_dispatch_preconditions = alloc.dupe(wgsl_ir.TextureDispatchPrecondition, sm.texture_dispatch_preconditions) catch {
        metal_bridge_release(pso);
        if (cp.dispatch_preconditions.len > 0) alloc.free(cp.dispatch_preconditions);
        alloc.destroy(cp);
        return null;
    };
    const result = toOpaque(cp);
    label_store.set(result, d.label.data, d.label.length);
    return result;
}

fn doeNativeDeviceCreateComputePipelineMainOwned(dev_raw: ?*anyopaque, shader_raw: ?*anyopaque, layout_raw: ?*anyopaque, diagnostic: *ShaderDiagnostic) ?*anyopaque {
    const main_entry = "main";
    var desc = abi_pipeline.WGPUComputePipelineDescriptor{
        .nextInChain = null,
        .label = .{ .data = null, .length = 0 },
        .layout = @ptrCast(layout_raw),
        .compute = .{
            .nextInChain = null,
            .module = @ptrCast(shader_raw),
            .entryPoint = .{ .data = main_entry.ptr, .length = main_entry.len },
            .constantCount = 0,
            .constants = null,
        },
    };
    return doeNativeDeviceCreateComputePipelineOwned(dev_raw, &desc, diagnostic);
}

pub export fn doeNativeComputePipelineRelease(raw: ?*anyopaque) callconv(.c) void {
    if (cast(DoeComputePipeline, raw)) |p| {
        if (!native_helpers.object_should_destroy(p)) return;
        label_store.remove(raw);
        if (p.mtl_pso) |pso| metal_bridge_release(pso);
        if (p.dispatch_preconditions.len > 0) alloc.free(p.dispatch_preconditions);
        if (p.texture_dispatch_preconditions.len > 0) alloc.free(p.texture_dispatch_preconditions);
        if (p.layout) |layout| bind_group.doeNativePipelineLayoutRelease(toOpaque(layout));
        if (p.shader_module) |shader_module| doeNativeShaderModuleRelease(toOpaque(shader_module));
        const vk_compute = @import("../vulkan/vulkan_compute_native.zig");
        vk_compute.vulkan_release_compute_pipeline(p);
        alloc.destroy(p);
    }
}

fn retainWgslSourceOwned(wgsl: []const u8, diagnostic: *ShaderDiagnostic) ?[]const u8 {
    return retainWgslSourceWithAllocator(alloc, wgsl, diagnostic);
}

fn retainWgslSourceWithAllocator(allocator: std.mem.Allocator, wgsl: []const u8, diagnostic: *ShaderDiagnostic) ?[]const u8 {
    return allocator.dupe(u8, wgsl) catch {
        diagnostic.set_last_error_stage_name("native_shader_create");
        diagnostic.set_last_error_kind("OutOfMemory");
        diagnostic.set_last_error("retaining required WGSL source failed: OutOfMemory");
        return null;
    };
}

pub export fn doeNativeCheckShaderSource(code_ptr: ?[*]const u8, code_len: usize) callconv(.c) u32 {
    var diagnostic = ShaderDiagnostic{};
    defer last_diagnostic = diagnostic;
    return doeNativeCheckShaderSourceOwned(code_ptr, code_len, &diagnostic);
}

pub export fn doeNativeShaderModuleGetBindings(raw: ?*anyopaque, out_ptr: ?[*]native_shared.BindingInfo, out_len: usize) callconv(.c) usize {
    var diagnostic = ShaderDiagnostic{};
    defer last_diagnostic = diagnostic;
    return doeNativeShaderModuleGetBindingsOwned(raw, out_ptr, out_len, &diagnostic);
}

pub export fn doeNativeDeviceCreateComputePipeline(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUComputePipelineDescriptor) callconv(.c) ?*anyopaque {
    var diagnostic = ShaderDiagnostic{};
    defer last_diagnostic = diagnostic;
    return doeNativeDeviceCreateComputePipelineOwned(dev_raw, desc, &diagnostic);
}

pub export fn doeNativeDeviceCreateShaderModuleWgsl(dev_raw: ?*anyopaque, code_ptr: ?[*]const u8, code_len: usize) callconv(.c) ?*anyopaque {
    var diagnostic = ShaderDiagnostic{};
    defer last_diagnostic = diagnostic;
    return doeNativeDeviceCreateShaderModuleWgslOwned(dev_raw, code_ptr, code_len, &diagnostic);
}

pub export fn doeNativeDeviceCreateShaderModule(dev_raw: ?*anyopaque, desc: ?*const abi_pipeline.WGPUShaderModuleDescriptor) callconv(.c) ?*anyopaque {
    var diagnostic = ShaderDiagnostic{};
    defer last_diagnostic = diagnostic;
    return doeNativeDeviceCreateShaderModuleOwned(dev_raw, desc, &diagnostic);
}

pub export fn doeNativeDeviceCreateComputePipelineMain(dev_raw: ?*anyopaque, shader_raw: ?*anyopaque, layout_raw: ?*anyopaque) callconv(.c) ?*anyopaque {
    var diagnostic = ShaderDiagnostic{};
    defer last_diagnostic = diagnostic;
    return doeNativeDeviceCreateComputePipelineMainOwned(dev_raw, shader_raw, layout_raw, &diagnostic);
}

pub export fn doeNativeShaderModuleGetBindingsForEntryPoint(raw: ?*anyopaque, entry_ptr: ?[*]const u8, entry_len: usize, out_ptr: ?[*]native_shared.BindingInfo, out_len: usize) callconv(.c) usize {
    var diagnostic = ShaderDiagnostic{};
    defer last_diagnostic = diagnostic;
    return doeNativeShaderModuleGetBindingsForEntryPointOwned(raw, entry_ptr, entry_len, out_ptr, out_len, &diagnostic);
}

fn sourceRetentionFailure(allocator: std.mem.Allocator) !void {
    var diagnostic = ShaderDiagnostic{};
    const source = retainWgslSourceWithAllocator(allocator, "shader source", &diagnostic) orelse {
        try std.testing.expectEqualStrings("OutOfMemory", diagnostic.last_error_kind_buf[0..diagnostic.last_error_kind_len]);
        try std.testing.expect(diagnostic.last_error_len > 0);
        return error.OutOfMemory;
    };
    defer allocator.free(source);
    try std.testing.expectEqualStrings("shader source", source);
}

test "required shader source retention propagates allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, sourceRetentionFailure, .{});
}
