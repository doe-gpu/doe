const std = @import("std");
const analysis = @import("analysis.zig");
const ir = @import("../ir/ir.zig");
pub const emitter = @import("../emit/dxil/emit_dxil.zig");
pub const MAX_OUTPUT: usize = emitter.MAX_OUTPUT;
pub const DXC_ENV_VAR: []const u8 = emitter.DXC_ENV_VAR;
pub const DXC_PATH_SENTINEL: []const u8 = emitter.DXC_PATH_SENTINEL;
pub const ToolchainConfig = emitter.ToolchainConfig;
pub const ToolchainDiscovery = emitter.ToolchainDiscovery;

pub fn translateToDxil(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) analysis.TranslateError!usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var module_ir = try analysis.analyzeToIr(arena.allocator(), wgsl);

    return emitter.emit(&module_ir, out) catch |err| {
        const detail = emitter.lastErrorMessage();
        const kind = switch (err) {
            error.OutputTooLarge => analysis.TranslateError.OutputTooLarge,
            error.UnsupportedBuiltin => analysis.TranslateError.UnsupportedBuiltin,
            error.UnsupportedConstruct => analysis.TranslateError.UnsupportedConstruct,
            error.InvalidIr => analysis.TranslateError.InvalidIr,
            error.OutOfMemory => analysis.TranslateError.OutOfMemory,
            error.ShaderToolchainUnavailable => analysis.TranslateError.ShaderToolchainUnavailable,
        };
        if (detail.len != 0)
            analysis.setLastErrorDetailPublic(.dxil_emit, kind, detail)
        else
            analysis.setLastError(.dxil_emit, kind, null, null);
        return kind;
    };
}

pub fn translateToDxilWithToolchainConfig(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
    config: emitter.ToolchainConfig,
) analysis.TranslateError!usize {
    var module_ir = try analysis.analyzeToIr(allocator, wgsl);
    defer module_ir.deinit();

    return emitter.emitWithToolchainConfig(&module_ir, out, config) catch |err| {
        const detail = emitter.lastErrorMessage();
        const kind = switch (err) {
            error.OutputTooLarge => analysis.TranslateError.OutputTooLarge,
            error.UnsupportedBuiltin => analysis.TranslateError.UnsupportedBuiltin,
            error.UnsupportedConstruct => analysis.TranslateError.UnsupportedConstruct,
            error.InvalidIr => analysis.TranslateError.InvalidIr,
            error.OutOfMemory => analysis.TranslateError.OutOfMemory,
            error.ShaderToolchainUnavailable => analysis.TranslateError.ShaderToolchainUnavailable,
        };
        if (detail.len != 0)
            analysis.setLastErrorDetailPublic(.dxil_emit, kind, detail)
        else
            analysis.setLastError(.dxil_emit, kind, null, null);
        return kind;
    };
}
