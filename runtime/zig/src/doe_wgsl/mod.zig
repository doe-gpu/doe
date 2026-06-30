// doe_wgsl/mod.zig — WGSL compiler module entry point.
//
// Public API for parsing WGSL source, validating it through semantic analysis,
// lowering it to typed IR, and then invoking legacy backend emitters.

pub const token = @import("token.zig");
pub const lexer = @import("lexer.zig");
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const sema = @import("sema.zig");
pub const ir = @import("ir.zig");
pub const ir_builder = @import("ir_builder.zig");
pub const ir_validate = @import("ir_validate.zig");
pub const ir_opt_rewrite = @import("ir_opt_rewrite.zig");
pub const ir_transform_robustness = @import("ir_transform_robustness.zig");
pub const emit_msl = @import("emit_msl.zig");
pub const emit_msl_subgroups = @import("emit_msl_subgroups.zig");
pub const emit_msl_shared = @import("emit_msl_shared.zig");
pub const emit_msl_vertex = @import("emit_msl_vertex.zig");
pub const emit_msl_fragment = @import("emit_msl_fragment.zig");
pub const emit_hlsl = @import("emit_hlsl.zig");
pub const hlsl_dispatch_contract = @import("hlsl_dispatch_contract.zig");
pub const emit_hlsl_texture = @import("emit_hlsl_texture.zig");
pub const emit_spirv = @import("emit_spirv.zig");
pub const emit_spirv_fn = @import("emit_spirv_fn.zig");
pub const emit_spirv_stages = @import("emit_spirv_stages.zig");
pub const emit_spirv_texture = @import("emit_spirv_texture.zig");
pub const emit_dxil = @import("emit_dxil.zig");
pub const emit_csl = @import("emit_csl.zig");
pub const emit_csl_reduce_dist = @import("emit_csl_reduce_dist.zig");
pub const emit_csl_attention = @import("emit_csl_attention.zig");
pub const emit_csl_gather = @import("emit_csl_gather.zig");
pub const emit_csl_rope = @import("emit_csl_rope.zig");
pub const emit_csl_dequant = @import("emit_csl_dequant.zig");
pub const emit_csl_sample = @import("emit_csl_sample.zig");
pub const emit_csl_fused = @import("emit_csl_fused.zig");
pub const emit_csl_dense_gemv = @import("emit_csl_dense_gemv.zig");
pub const emit_csl_linear_attn = @import("emit_csl_linear_attn.zig");
pub const emit_csl_kv_cache = @import("emit_csl_kv_cache.zig");
pub const emit_csl_fused_ffn = @import("emit_csl_fused_ffn.zig");
pub const emit_csl_host = @import("emit_csl_host.zig");
pub const emit_csl_host_plan = @import("emit_csl_host_plan.zig");
pub const emit_csl_toolchain = @import("emit_csl_toolchain.zig");
pub const emit_csl_simulator = @import("emit_csl_simulator.zig");
pub const emit_csl_mem_plan = @import("emit_csl_mem_plan.zig");
pub const emit_csl_exec_v1 = @import("emit_csl_exec_v1.zig");
pub const emit_csl_host_runtime = @import("emit_csl_host_runtime.zig");
pub const emit_csl_validate = @import("emit_csl_validate.zig");
const csl_tests = @import("doe_wgsl_csl_tests.zig");
pub const layout_utils = @import("layout_utils.zig");
const lean_proof = @import("../lean_proof.zig");
const std = @import("std");

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

pub const MAX_OUTPUT: usize = emit_msl.MAX_OUTPUT;
pub const MAX_HLSL_OUTPUT: usize = emit_hlsl.MAX_OUTPUT;
pub const MAX_SPIRV_OUTPUT: usize = emit_spirv.MAX_OUTPUT;
pub const MAX_DXIL_OUTPUT: usize = emit_dxil.MAX_OUTPUT;
pub const MAX_CSL_OUTPUT: usize = emit_csl.MAX_OUTPUT;
pub const DXIL_DXC_ENV_VAR: []const u8 = emit_dxil.DXC_ENV_VAR;
pub const DXIL_DXC_PATH_SENTINEL: []const u8 = emit_dxil.DXC_PATH_SENTINEL;
pub const DxilToolchainConfig = emit_dxil.ToolchainConfig;
pub const DxilToolchainDiscovery = emit_dxil.ToolchainDiscovery;
pub const CslValidationError = emit_csl_validate.Error;
pub const CslPatternKind = emit_csl_validate.PatternKind;
pub const CslValidationResult = emit_csl_validate.ValidationResult;
pub const CslToolchainConfig = emit_csl_validate.ToolchainConfig;
pub const CslToolchainDiscovery = emit_csl_validate.ToolchainDiscovery;
pub const CSLC_ENV_VAR = emit_csl_validate.CSLC_ENV_VAR;
pub const CSLC_PATH_SENTINEL = emit_csl_validate.CSLC_PATH_SENTINEL;
pub const MAX_BINDINGS: usize = 16;

pub const BindingKind = enum(u32) {
    buffer,
    sampler,
    texture,
    storage_texture,
};

pub const BindingMeta = struct {
    group: u32,
    binding: u32,
    kind: BindingKind,
    addr_space: ir.AddressSpace,
    access: ir.AccessMode,
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

fn setLastError(stage: CompilationStage, kind: TranslateError, source: ?[]const u8, loc: ?token.Token.Loc) void {
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

fn default_translation_robustness_config() ir_transform_robustness.Config {
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
    const result = try analyzeToIrWithConfigTimed(allocator, wgsl, config);
    return result.module;
}

pub fn analyzeToIrWithConfigTimed(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    config: ir_transform_robustness.Config,
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
    var semantic = sema.analyze(allocator, &tree) catch |err| {
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

pub fn extractBindings(allocator: std.mem.Allocator, wgsl: []const u8, out: []BindingMeta) TranslateError!usize {
    var module_ir = try analyzeToIr(allocator, wgsl);
    defer module_ir.deinit();

    var count: usize = 0;
    for (module_ir.globals.items) |global| {
        if (global.binding == null) continue;
        const binding_type, const binding_access = switch (module_ir.types.get(global.ty)) {
            .sampler, .sampler_comparison => .{ BindingKind.sampler, ir.AccessMode.read },
            .texture_2d, .texture_2d_array, .texture_cube, .texture_multisampled_2d, .texture_depth_2d, .texture_depth_cube, .texture_3d => .{ BindingKind.texture, ir.AccessMode.read },
            .storage_texture_2d => |storage_tex| .{ BindingKind.storage_texture, storage_tex.access },
            else => .{ BindingKind.buffer, global.access orelse switch (global.addr_space orelse .private) {
                .uniform => ir.AccessMode.read,
                .storage => ir.AccessMode.read_write,
                else => ir.AccessMode.read,
            } },
        };
        if (count >= out.len) break;
        out[count] = .{
            .group = global.binding.?.group,
            .binding = global.binding.?.binding,
            .kind = binding_type,
            .addr_space = global.addr_space orelse .handle,
            .access = binding_access,
        };
        count += 1;
    }
    return count;
}

pub fn translateToMsl(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) TranslateError!usize {
    return translateToMslWithOverrides(allocator, wgsl, out, null, 0);
}

pub fn translateToMslWithOverrides(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8, overrides: ?[*]const ir.OverrideEntry, override_count: usize) TranslateError!usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var module_ir = try analyzeToIr(arena.allocator(), wgsl);

    if (overrides != null and override_count > 0) {
        applyOverrides(&module_ir, overrides.?[0..override_count]);
    }

    return emit_msl.emit(&module_ir, out) catch |err| {
        const kind = switch (err) {
            error.OutputTooLarge => TranslateError.OutputTooLarge,
            error.InvalidIr => TranslateError.InvalidIr,
        };
        setLastError(.msl_emit, kind, null, null);
        return kind;
    };
}

/// Apply pipeline override constants to a compiled IR module.
/// For each override entry, find the matching global (by numeric @id key or name key)
/// and replace its initializer value. The override is then demoted to a const so the
/// emitter outputs a fixed value rather than a pipeline-overridable declaration.
pub fn applyOverrides(module: *ir.Module, overrides: []const ir.OverrideEntry) void {
    for (overrides) |entry| {
        // Try numeric id match first.
        const numeric_id = std.fmt.parseInt(u32, entry.key, 10) catch null;
        for (module.globals.items) |*global| {
            if (global.class != .override_) continue;
            const matched = if (numeric_id) |id|
                (global.override_id != null and global.override_id.? == id)
            else
                std.mem.eql(u8, global.name, entry.key);
            if (!matched) continue;
            // Replace the initializer with the override value.
            const scalar_type = switch (module.types.get(global.ty)) {
                .scalar => |s| s,
                else => continue,
            };
            global.initializer = switch (scalar_type) {
                .bool => .{ .bool = entry.value != 0.0 },
                .i32, .abstract_int => .{ .int = @bitCast(@as(i64, @intFromFloat(entry.value))) },
                .u32 => .{ .int = @intFromFloat(entry.value) },
                .f32, .f16, .abstract_float => .{ .float = entry.value },
                else => continue,
            };
            // Demote to const so emitter outputs a fixed constant.
            global.class = .const_;
            break;
        }
    }
}

pub fn translateToHlsl(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) TranslateError!usize {
    return translateToHlslWithOverrides(allocator, wgsl, out, null, 0);
}

pub fn translateToHlslWithOverrides(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
    overrides: ?[*]const ir.OverrideEntry,
    override_count: usize,
) TranslateError!usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var module_ir = try analyzeToIr(arena.allocator(), wgsl);

    if (overrides != null and override_count > 0) {
        applyOverrides(&module_ir, overrides.?[0..override_count]);
    }

    return emit_hlsl.emit(&module_ir, out) catch |err| {
        const kind = switch (err) {
            error.OutputTooLarge => TranslateError.OutputTooLarge,
            error.InvalidIr => TranslateError.InvalidIr,
            error.UnsupportedBuiltin => TranslateError.UnsupportedBuiltin,
        };
        setLastError(.hlsl_emit, kind, null, null);
        return kind;
    };
}

pub fn translateToSpirv(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) TranslateError!usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var module_ir = try analyzeToIr(arena.allocator(), wgsl);

    return emit_spirv.emit(&module_ir, out) catch |err| {
        const kind = switch (err) {
            error.OutputTooLarge => TranslateError.OutputTooLarge,
            error.UnsupportedConstruct => TranslateError.UnsupportedConstruct,
            error.InvalidIr => TranslateError.InvalidIr,
            error.OutOfMemory => TranslateError.OutOfMemory,
        };
        setLastError(.spirv_emit, kind, null, null);
        return kind;
    };
}

pub fn translateToDxil(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) TranslateError!usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var module_ir = try analyzeToIr(arena.allocator(), wgsl);

    return emit_dxil.emit(&module_ir, out) catch |err| {
        const detail = emit_dxil.lastErrorMessage();
        const kind = switch (err) {
            error.OutputTooLarge => TranslateError.OutputTooLarge,
            error.UnsupportedBuiltin => TranslateError.UnsupportedBuiltin,
            error.UnsupportedConstruct => TranslateError.UnsupportedConstruct,
            error.InvalidIr => TranslateError.InvalidIr,
            error.OutOfMemory => TranslateError.OutOfMemory,
            error.ShaderToolchainUnavailable => TranslateError.ShaderToolchainUnavailable,
        };
        if (detail.len != 0)
            setLastErrorDetail(.dxil_emit, kind, detail)
        else
            setLastError(.dxil_emit, kind, null, null);
        return kind;
    };
}

pub fn translateToDxilWithToolchainConfig(
    allocator: std.mem.Allocator,
    wgsl: []const u8,
    out: []u8,
    config: emit_dxil.ToolchainConfig,
) TranslateError!usize {
    var module_ir = try analyzeToIr(allocator, wgsl);
    defer module_ir.deinit();

    return emit_dxil.emitWithToolchainConfig(&module_ir, out, config) catch |err| {
        const detail = emit_dxil.lastErrorMessage();
        const kind = switch (err) {
            error.OutputTooLarge => TranslateError.OutputTooLarge,
            error.UnsupportedBuiltin => TranslateError.UnsupportedBuiltin,
            error.UnsupportedConstruct => TranslateError.UnsupportedConstruct,
            error.InvalidIr => TranslateError.InvalidIr,
            error.OutOfMemory => TranslateError.OutOfMemory,
            error.ShaderToolchainUnavailable => TranslateError.ShaderToolchainUnavailable,
        };
        if (detail.len != 0)
            setLastErrorDetail(.dxil_emit, kind, detail)
        else
            setLastError(.dxil_emit, kind, null, null);
        return kind;
    };
}

pub fn translateToCsl(allocator: std.mem.Allocator, wgsl: []const u8, out: []u8) TranslateError!usize {
    var module_ir = try analyzeToIr(allocator, wgsl);
    defer module_ir.deinit();

    return emit_csl.emit(&module_ir, out) catch |err| {
        const kind = switch (err) {
            error.OutputTooLarge => TranslateError.OutputTooLarge,
            error.InvalidIr => TranslateError.InvalidIr,
            error.UnsupportedBuiltin => TranslateError.UnsupportedBuiltin,
            error.UnsupportedConstruct => TranslateError.UnsupportedConstruct,
            error.UnsupportedPattern => TranslateError.UnsupportedPattern,
        };
        setLastError(.csl_emit, kind, null, null);
        return kind;
    };
}

pub fn loadCslToolchainConfig(allocator: std.mem.Allocator) emit_csl_validate.Error!emit_csl_validate.ToolchainConfig {
    return emit_csl_validate.loadToolchainConfig(allocator);
}

pub fn validateCslPattern(csl: []const u8, pattern: emit_csl_validate.PatternKind) emit_csl_validate.ValidationResult {
    return emit_csl_validate.validatePattern(csl, pattern);
}

pub fn validateCslPatternWithToolchainConfig(
    csl: []const u8,
    pattern: emit_csl_validate.PatternKind,
    config: emit_csl_validate.ToolchainConfig,
) emit_csl_validate.Error!emit_csl_validate.ValidationResult {
    return emit_csl_validate.validatePatternWithToolchainConfig(csl, pattern, config);
}

pub fn validateCslToolchainConfig(config: emit_csl_validate.ToolchainConfig) emit_csl_validate.Error!void {
    return emit_csl_validate.validateToolchainConfig(config);
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

test {
    _ = token;
    _ = lexer;
    _ = ast;
    _ = parser;
    _ = sema;
    _ = ir;
    _ = ir_builder;
    _ = ir_validate;
    _ = ir_opt_rewrite;
    _ = ir_transform_robustness;
    _ = emit_msl;
    _ = emit_msl_subgroups;
    _ = emit_msl_shared;
    _ = emit_msl_vertex;
    _ = emit_msl_fragment;
    _ = emit_hlsl;
    _ = emit_hlsl_texture;
    _ = emit_spirv;
    _ = emit_spirv_fn;
    _ = emit_spirv_stages;
    _ = emit_spirv_texture;
    _ = emit_dxil;
    _ = emit_csl;
    _ = emit_csl_reduce_dist;
    _ = emit_csl_attention;
    _ = emit_csl_gather;
    _ = emit_csl_rope;
    _ = emit_csl_dequant;
    _ = emit_csl_sample;
    _ = emit_csl_fused;
    _ = emit_csl_linear_attn;
    _ = emit_csl_kv_cache;
    _ = emit_csl_fused_ffn;
    _ = emit_csl_host;
    _ = emit_csl_toolchain;
    _ = emit_csl_mem_plan;
    _ = emit_csl_exec_v1;
    _ = emit_csl_host_runtime;
    _ = emit_csl_validate;
    _ = layout_utils;
    // Test files are registered in test_suite*.zig, not imported here,
    // to avoid bleeding failing tests into every consumer of mod.zig.
}

test "translate vertex shader with struct I/O to MSL" {
    const source =
        \\struct VertIn {
        \\    @location(0) pos: vec4f,
        \\    @location(1) uv: vec2f,
        \\}
        \\struct VertOut {
        \\    @builtin(position) clip_pos: vec4f,
        \\    @location(0) uv: vec2f,
        \\}
        \\@vertex
        \\fn vs_main(in: VertIn) -> VertOut {
        \\    var out: VertOut;
        \\    out.clip_pos = in.pos;
        \\    out.uv = in.uv;
        \\    return out;
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "vertex ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[position]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[attribute(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[attribute(1)]]") != null);
}

test "translate fragment shader with MRT output to MSL" {
    const source =
        \\@group(0) @binding(0) var my_texture: texture_2d<f32>;
        \\@group(0) @binding(1) var my_sampler: sampler;
        \\struct FragOut {
        \\    @location(0) color0: vec4f,
        \\    @location(1) color1: vec4f,
        \\}
        \\@fragment
        \\fn fs_main(@location(0) uv: vec2f) -> FragOut {
        \\    var out: FragOut;
        \\    out.color0 = textureSample(my_texture, my_sampler, uv);
        \\    out.color1 = vec4f(1.0, 0.0, 0.0, 1.0);
        \\    return out;
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "fragment ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[color(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[color(1)]]") != null);
}

test "translate fragment shader with builtin inputs and discard to MSL" {
    const source =
        \\@fragment
        \\fn fs_main(
        \\    @builtin(position) frag_coord: vec4f,
        \\    @builtin(front_facing) is_front: bool,
        \\) -> @location(0) vec4f {
        \\    if (!is_front) {
        \\        discard;
        \\    }
        \\    return vec4f(frag_coord.x, frag_coord.y, 0.0, 1.0);
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "fragment ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[position]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[front_facing]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "discard_fragment()") != null);
}

test "translate vertex shader with builtin vertex_index and instance_index to MSL" {
    const source =
        \\@vertex
        \\fn vs_main(
        \\    @builtin(vertex_index) vid: u32,
        \\    @builtin(instance_index) iid: u32,
        \\) -> @builtin(position) vec4f {
        \\    return vec4f(f32(vid), f32(iid), 0.0, 1.0);
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    try std.testing.expect(len > 0);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "vertex ") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[vertex_id]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "[[instance_id]]") != null);
}

test "robustness: sized array index emits min() in MSL output" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> data: array<f32, 16>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let idx = gid.x;
        \\    data[idx] = 1.0;
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    const msl = out[0..len];
    // The robustness pass should have injected min(idx, 15) for the array index.
    try std.testing.expect(std.mem.indexOf(u8, msl, "min(") != null);
}

test "robustness: guarded local stride workgroup index elides sized-array clamp" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> out: array<f32, 1>;
        \\var<workgroup> partial_sums: array<f32, 64>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(local_invocation_id) local_invocation_id: vec3u) {
        \\    let lane = local_invocation_id.x;
        \\    partial_sums[lane] = 1.0;
        \\    workgroupBarrier();
        \\    var stride = 32u;
        \\    loop {
        \\        if (stride == 0u) { break; }
        \\        if (lane < stride) {
        \\            partial_sums[lane] = partial_sums[lane] + partial_sums[lane + stride];
        \\        }
        \\        workgroupBarrier();
        \\        stride = stride >> 1u;
        \\    }
        \\    if (lane == 0u) {
        \\        out[0] = partial_sums[0];
        \\    }
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    const msl = out[0..len];
    try std.testing.expect(std.mem.indexOf(u8, msl, "partial_sums[min") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl, "min((lane + stride)") == null);
}

test "robustness: runtime-sized array index emits arrayLength in MSL output" {
    const source =
        \\@group(0) @binding(0) var<storage, read_write> buf: array<u32>;
        \\@compute @workgroup_size(64)
        \\fn main(@builtin(global_invocation_id) gid: vec3u) {
        \\    let idx = gid.x;
        \\    buf[idx] = 42u;
        \\}
    ;
    var out: [MAX_OUTPUT]u8 = undefined;
    const len = try translateToMsl(std.testing.allocator, source, &out);
    const msl = out[0..len];
    const expect_elided = lean_proof.boundsProven(.gid_1d_storage_buffer);
    try std.testing.expectEqual(!expect_elided, std.mem.indexOf(u8, msl, "min(") != null);
    try std.testing.expectEqual(!expect_elided, std.mem.indexOf(u8, msl, "_doe_sizes") != null);
}

test "arrayLength(&buf) in comparison compiles" {
    try csl_tests.expectArrayLengthInComparisonCompiles(std.testing.allocator, translateToMsl, MAX_OUTPUT);
}
test "robustness: runtime-sized constant index coerces abstract int for MSL min()" {
    try csl_tests.expectRuntimeSizedConstantIndexCoercesAbstractIntForMslMin(std.testing.allocator, translateToMsl, MAX_OUTPUT);
}
test "robustness: vertex array clamp coerces u32 literal for MSL min()" {
    try csl_tests.expectVertexArrayClampCoercesU32LiteralForMslMin(std.testing.allocator, translateToMsl, MAX_OUTPUT);
}
test "arrayLength on struct member compiles to MSL" {
    try csl_tests.expectArrayLengthOnStructMemberCompilesToMsl(std.testing.allocator, translateToMsl, MAX_OUTPUT);
}
test "arrayLength on struct member compiles to HLSL" {
    try csl_tests.expectArrayLengthOnStructMemberCompilesToHlsl(std.testing.allocator, translateToHlsl, MAX_HLSL_OUTPUT);
}
test "arrayLength on struct member compiles to SPIR-V" {
    try csl_tests.expectArrayLengthOnStructMemberCompilesToSpirv(std.testing.allocator, translateToSpirv, MAX_SPIRV_OUTPUT);
}
test "translate element-wise compute shader to CSL" {
    try csl_tests.expectElementWiseComputeShaderCompilesToCsl(std.testing.allocator, translateToCsl, MAX_CSL_OUTPUT);
}
test "vertex shader rejected for CSL emission" {
    try csl_tests.expectVertexShaderRejectedForCsl(std.testing.allocator, translateToCsl, TranslateError.UnsupportedConstruct, MAX_CSL_OUTPUT);
}
