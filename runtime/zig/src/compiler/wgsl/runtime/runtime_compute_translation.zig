const std = @import("std");
const ir = @import("../ir/ir.zig");
const analysis = @import("../pipeline/analysis.zig");
const override_values = @import("../pipeline/overrides.zig");
const robustness = @import("../ir/ir_transform_robustness.zig");
const emit_msl = @import("../emit/msl/emit_msl.zig");
const emit_spirv = @import("../emit/spirv/emit_spirv.zig");
const translate_spirv = @import("../pipeline/translate_spirv.zig");
const translation_info = @import("runtime_translation_info.zig");

pub const TranslationInfo = translation_info.TranslationInfo;
pub const TranslationResult = translation_info.TranslationResult;
pub const TimedTranslationResult = translation_info.TimedTranslationResult;

const MIN_RECORDED_PHASE_NS: u64 = 1;

fn nowNs() i128 {
    return std.time.nanoTimestamp();
}

fn elapsedNs(start: i128, end: i128) u64 {
    if (end <= start) return MIN_RECORDED_PHASE_NS;
    const elapsed: u64 = @intCast(end - start);
    return @max(elapsed, MIN_RECORDED_PHASE_NS);
}

pub fn compute_runtime_robustness_config() robustness.Config {
    return .{
        // Dispatch-dependent elision is unsafe until the runtime can execute a
        // retained robust artifact when a host precondition fails. Rejecting
        // the optimized dispatch after encoding has begun silently drops GPU
        // work and changes source semantics. Keep compile-time static elision,
        // but preserve runtime clamps for dispatch- and uniform-sized access.
        .elide_proven_bounds = false,
        .elide_dispatch_validated_bounds = false,
        .elide_dispatch_validated_global_bounds = false,
        .elide_static_storage_bounds = true,
        .elide_uniform_validated_bounds = false,
        .elide_proven_texture_bounds = false,
    };
}

pub fn vulkan_compute_runtime_robustness_config() robustness.Config {
    return .{
        .elide_proven_bounds = false,
        .elide_dispatch_validated_bounds = false,
        .elide_dispatch_validated_global_bounds = false,
        .elide_static_storage_bounds = true,
        .elide_uniform_validated_bounds = false,
        // The Vulkan device contract requires robustBufferAccess. Preserve
        // raw storage-buffer indices so hardware returns zero for OOB reads
        // and discards OOB writes instead of aliasing the final element.
        .rely_on_storage_buffer_robustness = true,
    };
}

fn emitSpirv(module_ir: *ir.Module, out: []u8, diagnostic: *analysis.Diagnostic) analysis.TranslateError!usize {
    try translate_spirv.prepareComputeIrWithDiagnostic(module_ir, diagnostic);
    return emit_spirv.emit(module_ir, out) catch |err| {
        const kind: analysis.TranslateError = switch (err) {
            error.OutputTooLarge => analysis.TranslateError.OutputTooLarge,
            error.UnsupportedConstruct => analysis.TranslateError.UnsupportedConstruct,
            error.InvalidIr => analysis.TranslateError.InvalidIr,
            error.OutOfMemory => analysis.TranslateError.OutOfMemory,
        };
        diagnostic.setLastErrorDetailPublic(.spirv_emit, kind, @errorName(err));
        return kind;
    };
}

pub fn translateToMslForComputeRuntimeWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, overrides: ?[*]const ir.OverrideEntry, override_count: usize, diagnostic: *analysis.Diagnostic) analysis.TranslateError!TranslationResult {
    const timed = try translateToMslForComputeRuntimeTimedWithDiagnostic(allocator, wgsl, out, overrides, override_count, diagnostic);
    return .{
        .len = timed.len,
        .info = timed.info,
    };
}

pub fn translateToMslForComputeRuntimeTimedWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, overrides: ?[*]const ir.OverrideEntry, override_count: usize, diagnostic: *analysis.Diagnostic) analysis.TranslateError!TimedTranslationResult {
    const total_start_ns = nowNs();
    const override_slice = if (overrides != null and override_count > 0)
        overrides.?[0..override_count]
    else
        &.{};
    var analyzed = try analysis.analyzeToIrWithConfigTimedAndOverridesWithDiagnostic(allocator, wgsl, compute_runtime_robustness_config(), override_slice, diagnostic);
    defer analyzed.module.deinit();

    if (override_slice.len > 0) override_values.applyOverrides(&analyzed.module, override_slice);

    const emit_start_ns = nowNs();
    const len = emit_msl.emit(&analyzed.module, out) catch |err| {
        diagnostic.setLastError(.msl_emit, err, null, null);
        return err;
    };
    const emit_end_ns = nowNs();
    var phase_timings_ns = analyzed.phase_timings_ns;
    phase_timings_ns.emit = elapsedNs(emit_start_ns, emit_end_ns);
    phase_timings_ns.total = elapsedNs(total_start_ns, emit_end_ns);
    return .{
        .len = len,
        .info = try translation_info.buildTranslationInfo(allocator, &analyzed.module),
        .phase_timings_ns = phase_timings_ns,
    };
}

pub fn translateToSpirvForComputeRuntimeWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, diagnostic: *analysis.Diagnostic) analysis.TranslateError!TranslationResult {
    var module_ir = try analysis.analyzeToIrWithConfigWithDiagnostic(allocator, wgsl, compute_runtime_robustness_config(), diagnostic);
    defer module_ir.deinit();

    const len = try emitSpirv(&module_ir, out, diagnostic);
    return .{
        .len = len,
        .info = try translation_info.buildTranslationInfo(allocator, &module_ir),
    };
}

pub fn translateToSpirvTimedWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, diagnostic: *analysis.Diagnostic) analysis.TranslateError!TimedTranslationResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const total_start_ns = nowNs();
    var analyzed = try analysis.analyzeToIrTimedWithDiagnostic(arena.allocator(), wgsl, diagnostic);

    const emit_start_ns = nowNs();
    const len = try emitSpirv(&analyzed.module, out, diagnostic);
    const emit_end_ns = nowNs();
    var phase_timings_ns = analyzed.phase_timings_ns;
    phase_timings_ns.emit = elapsedNs(emit_start_ns, emit_end_ns);
    phase_timings_ns.total = elapsedNs(total_start_ns, emit_end_ns);
    return .{
        .len = len,
        .info = try translation_info.buildTranslationInfo(allocator, &analyzed.module),
        .phase_timings_ns = phase_timings_ns,
    };
}

pub fn translateToSpirvForVulkanComputeRuntimeWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, diagnostic: *analysis.Diagnostic) analysis.TranslateError!TranslationResult {
    return translateToSpirvForVulkanComputeRuntimeWithOverridesWithDiagnostic(allocator, wgsl, out, null, 0, diagnostic);
}

pub fn translateToSpirvForVulkanComputeRuntimeWithOverridesWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, overrides: ?[*]const ir.OverrideEntry, override_count: usize, diagnostic: *analysis.Diagnostic) analysis.TranslateError!TranslationResult {
    const override_slice = if (overrides != null and override_count > 0)
        overrides.?[0..override_count]
    else
        &.{};
    var module_ir = try analysis.analyzeToIrWithConfigAndOverridesWithDiagnostic(allocator, wgsl, vulkan_compute_runtime_robustness_config(), override_slice, diagnostic);
    defer module_ir.deinit();

    if (override_slice.len > 0) override_values.applyOverrides(&module_ir, override_slice);

    const len = try emitSpirv(&module_ir, out, diagnostic);
    return .{
        .len = len,
        .info = try translation_info.buildTranslationInfo(allocator, &module_ir),
    };
}

pub fn translateToMslForComputeRuntime(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, overrides: ?[*]const ir.OverrideEntry, override_count: usize) analysis.TranslateError!TranslationResult {
    return translateToMslForComputeRuntimeWithDiagnostic(allocator, wgsl, out, overrides, override_count, analysis.compatibilityDiagnostic());
}

pub fn translateToMslForComputeRuntimeTimed(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, overrides: ?[*]const ir.OverrideEntry, override_count: usize) analysis.TranslateError!TimedTranslationResult {
    return translateToMslForComputeRuntimeTimedWithDiagnostic(allocator, wgsl, out, overrides, override_count, analysis.compatibilityDiagnostic());
}

pub fn translateToSpirvForComputeRuntime(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) analysis.TranslateError!TranslationResult {
    return translateToSpirvForComputeRuntimeWithDiagnostic(allocator, wgsl, out, analysis.compatibilityDiagnostic());
}

pub fn translateToSpirvTimed(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) analysis.TranslateError!TimedTranslationResult {
    return translateToSpirvTimedWithDiagnostic(allocator, wgsl, out, analysis.compatibilityDiagnostic());
}

pub fn translateToSpirvForVulkanComputeRuntime(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) analysis.TranslateError!TranslationResult {
    return translateToSpirvForVulkanComputeRuntimeWithDiagnostic(allocator, wgsl, out, analysis.compatibilityDiagnostic());
}

pub fn translateToSpirvForVulkanComputeRuntimeWithOverrides(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, overrides: ?[*]const ir.OverrideEntry, override_count: usize) analysis.TranslateError!TranslationResult {
    return translateToSpirvForVulkanComputeRuntimeWithOverridesWithDiagnostic(allocator, wgsl, out, overrides, override_count, analysis.compatibilityDiagnostic());
}
