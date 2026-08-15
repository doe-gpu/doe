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

pub const TranslateError = error{
    InvalidWgsl,
    InvalidIr,
    DuplicateSymbol,
    InvalidAttribute,
    InvalidType,
    OutputTooLarge,
    OutOfMemory,
    ShaderToolchainUnavailable,
    UnexpectedToken,
    TypeMismatch,
    UnknownIdentifier,
    UnknownType,
    UnsupportedBuiltin,
    UnsupportedConstruct,
    UnsupportedPattern,
    UnsupportedWgsl,
};

pub const CompilationStage = enum {
    none,
    parser,
    sema,
    ir_builder,
    ir_validate,
    ir_transform,
    msl_emit,
    hlsl_emit,
    spirv_emit,
    dxil_emit,
    csl_emit,
};

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

const LAST_ERROR_CAP: usize = 256;
const LAST_CONTEXT_CAP: usize = 96;
var last_error_buf: [LAST_ERROR_CAP]u8 = undefined;
var last_error_len: usize = 0;
var last_error_stage: CompilationStage = .none;
var last_error_kind: ?TranslateError = null;
var last_error_line: u32 = 0;
var last_error_column: u32 = 0;
var last_error_context_buf: [LAST_CONTEXT_CAP]u8 = undefined;
var last_error_context_len: usize = 0;

pub const SourceLocation = struct {
    line: u32,
    column: u32,
};

pub const LastErrorInfo = struct {
    stage: CompilationStage,
    kind: ?TranslateError,
    location: ?SourceLocation,
    context: []const u8,
};

fn clearLastError() void {
    last_error_stage = .none;
    last_error_kind = null;
    last_error_len = 0;
    last_error_line = 0;
    last_error_column = 0;
    last_error_context_len = 0;
}

pub fn setLastError(stage: CompilationStage, kind: TranslateError, source: ?[]const u8, loc: ?token.Token.Loc) void {
    last_error_stage = stage;
    last_error_kind = kind;
    recordSourceContext(source, loc);
    const text = (if (last_error_line != 0 and last_error_context_len != 0)
        std.fmt.bufPrint(&last_error_buf, "{s}: {s} at {d}:{d} near `{s}`", .{
            @tagName(stage),
            @errorName(kind),
            last_error_line,
            last_error_column,
            last_error_context_buf[0..last_error_context_len],
        })
    else
        std.fmt.bufPrint(&last_error_buf, "{s}: {s}", .{
            @tagName(stage),
            @errorName(kind),
        })) catch {
        last_error_len = 0;
        return;
    };
    last_error_len = text.len;
}

pub fn setLastErrorDetailPublic(stage: CompilationStage, kind: TranslateError, detail: []const u8) void {
    setLastErrorDetail(stage, kind, detail);
}

fn setLastErrorDetail(stage: CompilationStage, kind: TranslateError, detail: []const u8) void {
    last_error_stage = stage;
    last_error_kind = kind;
    last_error_line = 0;
    last_error_column = 0;
    last_error_context_len = 0;
    const text = std.fmt.bufPrint(&last_error_buf, "{s}: {s}: {s}", .{
        @tagName(stage),
        @errorName(kind),
        detail,
    }) catch {
        last_error_len = 0;
        return;
    };
    last_error_len = text.len;
}

fn recordSourceContext(source: ?[]const u8, loc: ?token.Token.Loc) void {
    last_error_line = 0;
    last_error_column = 0;
    last_error_context_len = 0;

    const src = source orelse return;
    const span = loc orelse return;
    if (span.start > src.len or span.end > src.len or span.start > span.end) return;

    var line: u32 = 1;
    var column: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < span.start) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            column = 1;
            line_start = i + 1;
        } else {
            column += 1;
        }
    }

    var line_end = span.end;
    while (line_end < src.len and src[line_end] != '\n' and src[line_end] != '\r') : (line_end += 1) {}
    const full_line = src[line_start..line_end];
    const token_rel = span.start - line_start;

    var snippet_start: usize = 0;
    if (full_line.len > LAST_CONTEXT_CAP and token_rel > LAST_CONTEXT_CAP / 2) {
        snippet_start = token_rel - LAST_CONTEXT_CAP / 2;
        if (snippet_start + LAST_CONTEXT_CAP > full_line.len) {
            snippet_start = full_line.len - LAST_CONTEXT_CAP;
        }
    }
    const snippet = full_line[snippet_start..@min(full_line.len, snippet_start + LAST_CONTEXT_CAP)];
    @memcpy(last_error_context_buf[0..snippet.len], snippet);
    last_error_context_len = snippet.len;
    last_error_line = line;
    last_error_column = column;
}

fn tokenLoc(tree: *const ast.Ast, token_idx: ?u32) ?token.Token.Loc {
    const idx = token_idx orelse return null;
    if (idx >= tree.tokens.items.len) return null;
    return tree.tokens.items[idx].loc;
}

pub fn lastErrorKind() ?TranslateError {
    return last_error_kind;
}

pub fn lastErrorContext() []const u8 {
    return last_error_context_buf[0..last_error_context_len];
}

pub fn lastErrorInfo() LastErrorInfo {
    return .{
        .stage = last_error_stage,
        .kind = last_error_kind,
        .location = if (last_error_line == 0) null else .{
            .line = last_error_line,
            .column = last_error_column,
        },
        .context = last_error_context_buf[0..last_error_context_len],
    };
}

pub fn lastErrorStage() CompilationStage {
    return last_error_stage;
}

pub fn lastErrorMessage() []const u8 {
    return last_error_buf[0..last_error_len];
}

pub fn lastErrorLine() u32 {
    return last_error_line;
}

pub fn lastErrorColumn() u32 {
    return last_error_column;
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

pub fn analyzeToIr(allocator: std.mem.Allocator, wgsl: []const u8) TranslateError!ir.Module {
    return analyzeToIrWithConfig(allocator, wgsl, default_translation_robustness_config());
}

pub fn analyzeToIrTimed(allocator: std.mem.Allocator, wgsl: []const u8) TranslateError!TimedAnalyzeResult {
    return analyzeToIrWithConfigTimed(allocator, wgsl, default_translation_robustness_config());
}

pub fn analyzeToIrWithConfig(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    config: ir_transform_robustness.Config,
) TranslateError!ir.Module {
    const result = try analyzeToIrWithConfigTimedAndOverrides(allocator, wgsl, config, &.{});
    return result.module;
}

pub fn analyzeToIrWithConfigTimed(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    config: ir_transform_robustness.Config,
) TranslateError!TimedAnalyzeResult {
    return analyzeToIrWithConfigTimedAndOverrides(allocator, wgsl, config, &.{});
}

pub fn analyzeToIrWithConfigAndOverrides(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    config: ir_transform_robustness.Config,
    overrides: []const ir.OverrideEntry,
) TranslateError!ir.Module {
    const result = try analyzeToIrWithConfigTimedAndOverrides(allocator, wgsl, config, overrides);
    return result.module;
}

pub fn analyzeToIrWithConfigTimedAndOverrides(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    config: ir_transform_robustness.Config,
    overrides: []const ir.OverrideEntry,
) TranslateError!TimedAnalyzeResult {
    clearLastError();
    const total_start_ns = nowNs();
    const parse_start_ns = total_start_ns;
    var tree = parser.parseSource(allocator, wgsl) catch |err| {
        const kind = switch (err) {
            error.OutOfMemory => TranslateError.OutOfMemory,
            error.UnexpectedToken => TranslateError.UnexpectedToken,
        };
        const fail_loc = parser.lastFailureContext().loc;
        setLastError(.parser, kind, wgsl, fail_loc);
        return kind;
    };
    const parse_end_ns = nowNs();
    defer tree.deinit();

    const sema_start_ns = parse_end_ns;
    var semantic = sema.analyzeWithOverrides(allocator, &tree, overrides) catch |err| {
        const kind = mapSemanticError(err);
        setLastError(.sema, kind, tree.source, tokenLoc(&tree, sema.lastFailureContext().token_idx));
        return kind;
    };
    const sema_end_ns = nowNs();
    defer semantic.deinit();

    const lower_start_ns = sema_end_ns;
    var module = ir_builder.build(allocator, &tree, &semantic) catch |err| {
        const kind = mapIrBuildError(err);
        setLastError(.ir_builder, kind, tree.source, tokenLoc(&tree, ir_builder.lastFailureContext().token_idx));
        return kind;
    };
    errdefer module.deinit();
    // validator_elimination_available is true when -Dlean-verified=true and the
    // proof artifact contains both builder_soundness and ValidatorRedundant.
    // Together they prove that every sema-Ok + build-Ok IR already satisfies all
    // ir_validate.validate() checks, so the call is a proven no-op and is elided.
    if (!lean_proof.validator_elimination_available) {
        ir_validate.validate(&module) catch {
            setLastError(.ir_validate, TranslateError.InvalidIr, null, null);
            return TranslateError.InvalidIr;
        };
    }
    ir_transform_robustness.apply(allocator, &module, config) catch |err| {
        setLastErrorDetail(.ir_transform, TranslateError.InvalidIr, @errorName(err));
        return TranslateError.InvalidIr;
    };
    _ = ir_opt_rewrite.apply(allocator, &module) catch |err| {
        setLastErrorDetail(.ir_transform, TranslateError.InvalidIr, @errorName(err));
        return TranslateError.InvalidIr;
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
