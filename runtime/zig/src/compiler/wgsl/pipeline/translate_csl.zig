const std = @import("std");
const analysis = @import("analysis.zig");
const ir = @import("../ir/ir.zig");
pub const emitter = @import("../emit/csl/emit_csl.zig");
pub const validation = @import("../emit/csl/emit_csl_validate.zig");
pub const MAX_OUTPUT: usize = emitter.MAX_OUTPUT;
pub const ValidationError = validation.Error;
pub const PatternKind = validation.PatternKind;
pub const ValidationResult = validation.ValidationResult;
pub const ToolchainConfig = validation.ToolchainConfig;
pub const ToolchainDiscovery = validation.ToolchainDiscovery;
pub const CSLC_ENV_VAR = validation.CSLC_ENV_VAR;
pub const CSLC_PATH_SENTINEL = validation.CSLC_PATH_SENTINEL;

pub fn translateToCsl(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) analysis.TranslateError!usize {
    var module_ir = try analysis.analyzeToIr(allocator, wgsl);
    defer module_ir.deinit();

    return emitter.emit(&module_ir, out) catch |err| {
        const kind = switch (err) {
            error.OutputTooLarge => analysis.TranslateError.OutputTooLarge,
            error.InvalidIr => analysis.TranslateError.InvalidIr,
            error.UnsupportedBuiltin => analysis.TranslateError.UnsupportedBuiltin,
            error.UnsupportedConstruct => analysis.TranslateError.UnsupportedConstruct,
            error.UnsupportedPattern => analysis.TranslateError.UnsupportedPattern,
        };
        analysis.setLastError(.csl_emit, kind, null, null);
        return kind;
    };
}

pub fn loadCslToolchainConfig(allocator: std.mem.Allocator) validation.Error!validation.ToolchainConfig {
    return validation.loadToolchainConfig(allocator);
}

pub fn validateCslPattern(csl: []const u8, pattern: validation.PatternKind) validation.ValidationResult {
    return validation.validatePattern(csl, pattern);
}

pub fn validateCslPatternWithToolchainConfig(
    csl: []const u8,
    pattern: validation.PatternKind,
    config: validation.ToolchainConfig,
) validation.Error!validation.ValidationResult {
    return validation.validatePatternWithToolchainConfig(csl, pattern, config);
}

pub fn validateCslToolchainConfig(config: validation.ToolchainConfig) validation.Error!void {
    return validation.validateToolchainConfig(config);
}
