const std = @import("std");
const ir = @import("../ir/ir.zig");
const lean_proof = @import("../../../verification/lean_proof.zig");
const analysis = @import("../pipeline/analysis.zig");
const override_values = @import("../pipeline/overrides.zig");
const robustness = @import("../ir/ir_transform_robustness.zig");
const emit_msl = @import("../emit/msl/emit_msl.zig");
const emit_spirv = @import("../emit/spirv/emit_spirv.zig");
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
        .elide_proven_bounds = lean_proof.bounds_elimination_available,
        .elide_dispatch_validated_bounds = true,
        .elide_dispatch_validated_global_bounds = true,
        .elide_static_storage_bounds = true,
        .elide_uniform_validated_bounds = true,
        // Runtime translation carries dispatch preconditions into pipeline
        // metadata, so it can safely consume proof-backed texture clamp elision.
        .elide_proven_texture_bounds = lean_proof.boundsProven(.gid_texture_1d_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_2d_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_3d_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_1d_affine_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_2d_affine_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_3d_affine_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_1d_tiled_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_2d_tiled_dispatch_fit) or
            lean_proof.boundsProven(.gid_texture_3d_tiled_dispatch_fit),
    };
}

pub fn vulkan_compute_runtime_robustness_config() robustness.Config {
    return .{
        .elide_proven_bounds = lean_proof.bounds_elimination_available,
        .elide_dispatch_validated_bounds = true,
        .elide_dispatch_validated_global_bounds = true,
        .elide_static_storage_bounds = true,
        .elide_uniform_validated_bounds = true,
    };
}

fn emitSpirv(module_ir: *const ir.Module, out: []u8) analysis.TranslateError!usize {
    return emit_spirv.emit(module_ir, out) catch |err| {
        const kind: analysis.TranslateError = switch (err) {
            error.OutputTooLarge => analysis.TranslateError.OutputTooLarge,
            error.UnsupportedConstruct => analysis.TranslateError.UnsupportedConstruct,
            error.InvalidIr => analysis.TranslateError.InvalidIr,
            error.OutOfMemory => analysis.TranslateError.OutOfMemory,
        };
        analysis.setLastErrorDetailPublic(.spirv_emit, kind, @errorName(err));
        return kind;
    };
}

pub fn translateToMslForComputeRuntime(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
    overrides: ?[*]const ir.OverrideEntry,
    override_count: usize,
) analysis.TranslateError!TranslationResult {
    const timed = try translateToMslForComputeRuntimeTimed(
        allocator,
        wgsl,
        out,
        overrides,
        override_count,
    );
    return .{
        .len = timed.len,
        .info = timed.info,
    };
}

pub fn translateToMslForComputeRuntimeTimed(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
    overrides: ?[*]const ir.OverrideEntry,
    override_count: usize,
) analysis.TranslateError!TimedTranslationResult {
    const total_start_ns = nowNs();
    var analyzed = try analysis.analyzeToIrWithConfigTimed(allocator, wgsl, compute_runtime_robustness_config());
    defer analyzed.module.deinit();

    if (overrides != null and override_count > 0) {
        override_values.applyOverrides(&analyzed.module, overrides.?[0..override_count]);
    }

    const emit_start_ns = nowNs();
    const len = emit_msl.emit(&analyzed.module, out) catch |err| return switch (err) {
        error.OutputTooLarge => analysis.TranslateError.OutputTooLarge,
        error.InvalidIr => analysis.TranslateError.InvalidIr,
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

pub fn translateToSpirvForComputeRuntime(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
) analysis.TranslateError!TranslationResult {
    var module_ir = try analysis.analyzeToIrWithConfig(allocator, wgsl, compute_runtime_robustness_config());
    defer module_ir.deinit();

    const len = try emitSpirv(&module_ir, out);
    return .{
        .len = len,
        .info = try translation_info.buildTranslationInfo(allocator, &module_ir),
    };
}

pub fn translateToSpirvTimed(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
) analysis.TranslateError!TimedTranslationResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const total_start_ns = nowNs();
    var analyzed = try analysis.analyzeToIrTimed(arena.allocator(), wgsl);

    const emit_start_ns = nowNs();
    const len = try emitSpirv(&analyzed.module, out);
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

pub fn translateToSpirvForVulkanComputeRuntime(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
) analysis.TranslateError!TranslationResult {
    var module_ir = try analysis.analyzeToIrWithConfig(allocator, wgsl, vulkan_compute_runtime_robustness_config());
    defer module_ir.deinit();

    const len = try emitSpirv(&module_ir, out);
    return .{
        .len = len,
        .info = try translation_info.buildTranslationInfo(allocator, &module_ir),
    };
}
