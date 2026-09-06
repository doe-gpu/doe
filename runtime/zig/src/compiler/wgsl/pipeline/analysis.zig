const std = @import("std");
const token = @import("../frontend/token.zig");
const ast = @import("../frontend/ast.zig");
const parser = @import("../frontend/parser.zig");
const sema = @import("../frontend/sema.zig");
pub const ir = @import("../ir/ir.zig");
const ir_builder = @import("../ir/ir_builder.zig");
const ir_validate = @import("../ir/ir_validate.zig");
const ir_opt_rewrite = @import("../ir/ir_opt_rewrite.zig");
pub const ir_transform_robustness = @import("../ir/ir_transform_robustness.zig");
const lean_proof = @import("../../../verification/lean_proof.zig");

pub const diagnostics = @import("diagnostic.zig");
pub const Diagnostic = diagnostics.Diagnostic;
pub const TranslateError = diagnostics.TranslateError;
pub const CompilationStage = diagnostics.CompilationStage;
pub const SourceLocation = diagnostics.SourceLocation;
pub const LastErrorInfo = diagnostics.LastErrorInfo;

// Legacy last-error views expire at the next compilation on the calling thread.
threadlocal var compatibility_diagnostic = Diagnostic{};
pub fn compatibilityDiagnostic() *Diagnostic {
    return &compatibility_diagnostic;
}
pub fn clearLastError() void {
    return compatibility_diagnostic.clearLastError();
}
pub fn lastErrorKind() ?TranslateError {
    return compatibility_diagnostic.lastErrorKind();
}
pub fn lastErrorContext() []const u8 {
    return compatibility_diagnostic.lastErrorContext();
}
pub fn lastErrorInfo() LastErrorInfo {
    return compatibility_diagnostic.lastErrorInfo();
}
pub fn lastErrorStage() CompilationStage {
    return compatibility_diagnostic.lastErrorStage();
}
pub fn lastErrorMessage() []const u8 {
    return compatibility_diagnostic.lastErrorMessage();
}
pub fn lastErrorLine() u32 {
    return compatibility_diagnostic.lastErrorLine();
}
pub fn lastErrorColumn() u32 {
    return compatibility_diagnostic.lastErrorColumn();
}
pub fn setLastError(stage: CompilationStage, kind: TranslateError, source: ?[]const u8, loc: ?token.Token.Loc) void {
    compatibility_diagnostic.setLastError(stage, kind, source, loc);
}
pub fn setLastErrorDetailPublic(stage: CompilationStage, kind: TranslateError, detail: []const u8) void {
    compatibility_diagnostic.setLastErrorDetailPublic(stage, kind, detail);
}

pub const CompilePhaseTimingsNs = struct {
    parse: u64 = 0,
    sema: u64 = 0,
    lower: u64 = 0,
    emit: u64 = 0,
    total: u64 = 0,
};

pub const TimedAnalyzeResult = struct {
    module: ir.Module,
    phase_timings_ns: CompilePhaseTimingsNs,
};

fn tokenLoc(tree: *const ast.Ast, token_idx: ?u32) ?token.Token.Loc {
    const idx = token_idx orelse return null;
    if (idx >= tree.tokens.items.len) return null;
    return tree.tokens.items[idx].loc;
}

pub fn default_translation_robustness_config() ir_transform_robustness.Config {
    return .{
        .elide_proven_bounds = lean_proof.bounds_elimination_available,
    };
}

fn nowNs() i128 {
    return std.time.nanoTimestamp();
}

fn elapsedNs(start: i128, end: i128) u64 {
    if (end <= start) return 0;
    return @intCast(end - start);
}

pub fn analyzeToIrWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, diagnostic: *Diagnostic) TranslateError!ir.Module {
    return analyzeToIrWithConfigWithDiagnostic(allocator, wgsl, default_translation_robustness_config(), diagnostic);
}

pub fn analyzeToIrTimedWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, diagnostic: *Diagnostic) TranslateError!TimedAnalyzeResult {
    return analyzeToIrWithConfigTimedWithDiagnostic(allocator, wgsl, default_translation_robustness_config(), diagnostic);
}

pub fn analyzeToIrWithConfigWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, config: ir_transform_robustness.Config, diagnostic: *Diagnostic) TranslateError!ir.Module {
    const result = try analyzeToIrWithConfigTimedAndOverridesWithDiagnostic(allocator, wgsl, config, &.{}, diagnostic);
    return result.module;
}

pub fn analyzeToIrWithConfigTimedWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, config: ir_transform_robustness.Config, diagnostic: *Diagnostic) TranslateError!TimedAnalyzeResult {
    return analyzeToIrWithConfigTimedAndOverridesWithDiagnostic(allocator, wgsl, config, &.{}, diagnostic);
}

pub fn analyzeToIrWithConfigAndOverridesWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, config: ir_transform_robustness.Config, overrides: []const ir.OverrideEntry, diagnostic: *Diagnostic) TranslateError!ir.Module {
    const result = try analyzeToIrWithConfigTimedAndOverridesWithDiagnostic(allocator, wgsl, config, overrides, diagnostic);
    return result.module;
}

pub fn analyzeToIrWithConfigTimedAndOverridesWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, config: ir_transform_robustness.Config, overrides: []const ir.OverrideEntry, diagnostic: *Diagnostic) TranslateError!TimedAnalyzeResult {
    return analyzeWithDiagnostic(allocator, wgsl, config, overrides, diagnostic);
}

pub fn analyzeWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, config: ir_transform_robustness.Config, overrides: []const ir.OverrideEntry, diagnostic: *Diagnostic) TranslateError!TimedAnalyzeResult {
    diagnostic.clearLastError();
    var parse_failure = parser.FailureContext{};
    var sema_failure = sema.FailureContext{};
    var build_failure = ir_builder.FailureContext{};
    const total_start_ns = nowNs();
    const parse_start_ns = total_start_ns;
    var tree = parser.parseSourceWithContext(allocator, wgsl, &parse_failure) catch |err| {
        const kind = switch (err) {
            error.OutOfMemory => TranslateError.OutOfMemory,
            error.UnexpectedToken => TranslateError.UnexpectedToken,
        };
        const fail_loc = parse_failure.loc;
        diagnostic.setLastError(.parser, kind, wgsl, fail_loc);
        return kind;
    };
    const parse_end_ns = nowNs();
    defer tree.deinit();

    const sema_start_ns = parse_end_ns;
    var semantic = sema.analyzeWithContext(allocator, &tree, overrides, &sema_failure) catch |err| {
        const kind = mapSemanticError(err);
        diagnostic.setLastError(.sema, kind, tree.source, tokenLoc(&tree, sema_failure.token_idx));
        return kind;
    };
    const sema_end_ns = nowNs();
    defer semantic.deinit();

    const lower_start_ns = sema_end_ns;
    var module = ir_builder.buildWithContext(allocator, &tree, &semantic, &build_failure) catch |err| {
        const kind = mapIrBuildError(err);
        diagnostic.setLastError(.ir_builder, kind, tree.source, tokenLoc(&tree, build_failure.token_idx));
        return kind;
    };
    errdefer module.deinit();
    // validator_elimination_available is true when -Dlean-verified=true and the
    // proof artifact contains both builder_soundness and ValidatorRedundant.
    // Together they prove that every sema-Ok + build-Ok IR already satisfies all
    // ir_validate.validate() checks, so the call is a proven no-op and is elided.
    if (!lean_proof.validator_elimination_available) {
        ir_validate.validate(&module) catch {
            diagnostic.setLastError(.ir_validate, TranslateError.InvalidIr, null, null);
            return TranslateError.InvalidIr;
        };
    }
    ir_transform_robustness.apply(allocator, &module, config) catch |err| {
        diagnostic.setLastErrorDetailPublic(.ir_transform, err, @errorName(err));
        return err;
    };
    _ = ir_opt_rewrite.apply(allocator, &module) catch |err| {
        diagnostic.setLastErrorDetailPublic(.ir_transform, err, @errorName(err));
        return err;
    };
    const lower_end_ns = nowNs();
    return .{
        .module = module,
        .phase_timings_ns = .{
            .parse = elapsedNs(parse_start_ns, parse_end_ns),
            .sema = elapsedNs(sema_start_ns, sema_end_ns),
            .lower = elapsedNs(lower_start_ns, lower_end_ns),
            .total = elapsedNs(total_start_ns, lower_end_ns),
        },
    };
}

fn mapSemanticError(err: anyerror) TranslateError {
    return switch (err) {
        error.OutOfMemory => TranslateError.OutOfMemory,
        error.UnsupportedConstruct => TranslateError.UnsupportedConstruct,
        error.UnsupportedBuiltin => TranslateError.UnsupportedBuiltin,
        error.DuplicateSymbol => TranslateError.DuplicateSymbol,
        error.InvalidAttribute => TranslateError.InvalidAttribute,
        error.InvalidType => TranslateError.InvalidType,
        error.TypeMismatch => TranslateError.TypeMismatch,
        error.UnknownIdentifier => TranslateError.UnknownIdentifier,
        error.UnknownType => TranslateError.UnknownType,
        error.InvalidWgsl => TranslateError.InvalidWgsl,
        else => TranslateError.InvalidWgsl,
    };
}

fn mapIrBuildError(err: anyerror) TranslateError {
    return switch (err) {
        error.OutOfMemory => TranslateError.OutOfMemory,
        error.UnsupportedConstruct => TranslateError.UnsupportedConstruct,
        error.InvalidWgsl => TranslateError.InvalidWgsl,
        error.InvalidIr => TranslateError.InvalidIr,
        else => TranslateError.InvalidIr,
    };
}

pub fn analyzeToIr(allocator: std.mem.Allocator, wgsl: []const u8) TranslateError!ir.Module {
    return analyzeToIrWithDiagnostic(allocator, wgsl, &compatibility_diagnostic);
}

pub fn analyzeToIrTimed(allocator: std.mem.Allocator, wgsl: []const u8) TranslateError!TimedAnalyzeResult {
    return analyzeToIrTimedWithDiagnostic(allocator, wgsl, &compatibility_diagnostic);
}

pub fn analyzeToIrWithConfig(allocator: std.mem.Allocator, wgsl: []const u8, config: ir_transform_robustness.Config) TranslateError!ir.Module {
    return analyzeToIrWithConfigWithDiagnostic(allocator, wgsl, config, &compatibility_diagnostic);
}

pub fn analyzeToIrWithConfigTimed(allocator: std.mem.Allocator, wgsl: []const u8, config: ir_transform_robustness.Config) TranslateError!TimedAnalyzeResult {
    return analyzeToIrWithConfigTimedWithDiagnostic(allocator, wgsl, config, &compatibility_diagnostic);
}

pub fn analyzeToIrWithConfigAndOverrides(allocator: std.mem.Allocator, wgsl: []const u8, config: ir_transform_robustness.Config, overrides: []const ir.OverrideEntry) TranslateError!ir.Module {
    return analyzeToIrWithConfigAndOverridesWithDiagnostic(allocator, wgsl, config, overrides, &compatibility_diagnostic);
}

pub fn analyzeToIrWithConfigTimedAndOverrides(allocator: std.mem.Allocator, wgsl: []const u8, config: ir_transform_robustness.Config, overrides: []const ir.OverrideEntry) TranslateError!TimedAnalyzeResult {
    return analyzeToIrWithConfigTimedAndOverridesWithDiagnostic(allocator, wgsl, config, overrides, &compatibility_diagnostic);
}
