const std = @import("std");
const ir = @import("../ir/ir.zig");
const lean_proof = @import("../../../verification/lean_proof.zig");
const analysis = @import("../pipeline/analysis.zig");
const robustness = @import("../ir/ir_transform_robustness.zig");
const emit_spirv = @import("../emit/spirv/emit_spirv.zig");

pub const VertexInputAttr = struct {
    location: u32,
    builtin: ir.Builtin,
};

/// Inter-stage I/O variable extracted from the IR for pipeline reflection.
pub const InterStageVar = struct {
    location: u32,
    interpolation: ?ir.Interpolation,
    builtin: ir.Builtin,
};

/// Result of translating a WGSL module containing vertex and/or fragment entry
/// points into per-stage SPIR-V binaries. Caller owns all heap allocations and
/// must call deinit to release them.
pub const GraphicsTranslationResult = struct {
    vertex_spirv: ?[]const u32 = null,
    fragment_spirv: ?[]const u32 = null,
    vertex_input_attrs: []const VertexInputAttr = &.{},
    inter_stage_vars: []const InterStageVar = &.{},
    has_vertex: bool = false,
    has_fragment: bool = false,

    pub fn deinit(self: *GraphicsTranslationResult, allocator: std.mem.Allocator) void {
        if (self.vertex_spirv) |s| allocator.free(s);
        if (self.fragment_spirv) |s| allocator.free(s);
        if (self.vertex_input_attrs.len > 0) allocator.free(self.vertex_input_attrs);
        if (self.inter_stage_vars.len > 0) allocator.free(self.inter_stage_vars);
        self.* = .{};
    }
};

/// Graphics shaders use the same robustness config as compute — Lean proof
/// elimination applies to any array bounds regardless of pipeline stage.
fn graphics_runtime_robustness_config() robustness.Config {
    return .{
        .elide_proven_bounds = lean_proof.bounds_elimination_available,
    };
}

/// Translate WGSL source containing vertex and/or fragment entry points into
/// separate per-stage SPIR-V binaries. Returns heap-allocated u32 word slices
/// for each stage found, plus extracted vertex input and inter-stage interface
/// metadata for pipeline reflection.
pub fn translateToSpirvForGraphicsRuntimeWithDiagnostic(allocator: std.mem.Allocator, wgsl: []const u8, diagnostic: *analysis.Diagnostic) analysis.TranslateError!GraphicsTranslationResult {
    var module_ir = try analysis.analyzeToIrWithConfigWithDiagnostic(allocator, wgsl, graphics_runtime_robustness_config(), diagnostic);
    defer module_ir.deinit();

    var result = GraphicsTranslationResult{};
    errdefer result.deinit(allocator);

    for (module_ir.entry_points.items) |entry| {
        switch (entry.stage) {
            .vertex => {
                if (result.has_vertex) continue;
                result.has_vertex = true;
                result.vertex_spirv = try emit_stage_spirv_wordsWithDiagnostic(allocator, &module_ir, .vertex, diagnostic);
            },
            .fragment => {
                if (result.has_fragment) continue;
                result.has_fragment = true;
                result.fragment_spirv = try emit_stage_spirv_wordsWithDiagnostic(allocator, &module_ir, .fragment, diagnostic);
            },
            .compute => {},
        }
    }

    result.vertex_input_attrs = try extract_vertex_inputs(allocator, &module_ir);
    result.inter_stage_vars = try extract_inter_stage_vars(allocator, &module_ir);

    return result;
}

/// Emit SPIR-V for a single stage and convert the byte output to heap-allocated u32 words.
fn emit_stage_spirv_wordsWithDiagnostic(allocator: std.mem.Allocator, module_ir: *const ir.Module, stage: ir.ShaderStage, diagnostic: *analysis.Diagnostic) analysis.TranslateError![]const u32 {
    var spirv_buf = allocator.alloc(u8, emit_spirv.MAX_OUTPUT) catch return analysis.TranslateError.OutOfMemory;
    defer allocator.free(spirv_buf);

    const len = emit_spirv.emitForStage(module_ir, stage, spirv_buf) catch |err| {
        const kind: analysis.TranslateError = switch (err) {
            error.OutputTooLarge => error.OutputTooLarge,
            error.UnsupportedConstruct => error.UnsupportedConstruct,
            error.InvalidIr => error.InvalidIr,
            error.OutOfMemory => error.OutOfMemory,
        };
        diagnostic.setLastErrorDetailPublic(.spirv_emit, kind, @errorName(err));
        return kind;
    };
    if (len == 0 or (len % @sizeOf(u32)) != 0) {
        diagnostic.setLastErrorDetailPublic(.spirv_emit, error.InvalidIr, "invalid SPIR-V word extent");
        return error.InvalidIr;
    }

    const word_count = len / 4;
    const words = allocator.alloc(u32, word_count) catch return analysis.TranslateError.OutOfMemory;
    for (words, 0..) |*w, i| {
        const offset = i * 4;
        const chunk: *const [4]u8 = @ptrCast(spirv_buf[offset .. offset + 4].ptr);
        w.* = std.mem.readInt(u32, chunk, .little);
    }
    return words;
}

const MAX_VERTEX_INPUT_ATTRS: usize = 32;
const MAX_INTER_STAGE_VARS: usize = 32;

/// Extract vertex input attributes (location-decorated parameters) from all
/// vertex entry points in the module.
fn extract_vertex_inputs(
    allocator: std.mem.Allocator,
    module_ir: *const ir.Module,
) analysis.TranslateError![]const VertexInputAttr {
    var attrs_buf: [MAX_VERTEX_INPUT_ATTRS]VertexInputAttr = undefined;
    var count: usize = 0;

    for (module_ir.entry_points.items) |entry| {
        if (entry.stage != .vertex) continue;
        const function = &module_ir.functions.items[entry.function];
        for (function.params.items) |param| {
            // Struct-typed params: each field is a separate vertex input.
            switch (module_ir.types.get(param.ty)) {
                .struct_ => |struct_id| {
                    const struct_def = module_ir.structs.items[struct_id];
                    for (struct_def.fields.items) |field| {
                        if (count >= MAX_VERTEX_INPUT_ATTRS) break;
                        const io = field.io orelse continue;
                        attrs_buf[count] = .{
                            .location = io.location orelse 0,
                            .builtin = io.builtin,
                        };
                        count += 1;
                    }
                },
                else => {
                    if (count >= MAX_VERTEX_INPUT_ATTRS) break;
                    const io = param.io orelse continue;
                    attrs_buf[count] = .{
                        .location = io.location orelse 0,
                        .builtin = io.builtin,
                    };
                    count += 1;
                },
            }
        }
    }

    if (count == 0) return &.{};
    return allocator.dupe(VertexInputAttr, attrs_buf[0..count]) catch return analysis.TranslateError.OutOfMemory;
}

/// Extract inter-stage interface variables from vertex output / fragment input.
/// These are the location-decorated fields of the vertex entry point return type.
fn extract_inter_stage_vars(
    allocator: std.mem.Allocator,
    module_ir: *const ir.Module,
) analysis.TranslateError![]const InterStageVar {
    var vars_buf: [MAX_INTER_STAGE_VARS]InterStageVar = undefined;
    var count: usize = 0;

    for (module_ir.entry_points.items) |entry| {
        if (entry.stage != .vertex) continue;
        const function = &module_ir.functions.items[entry.function];
        switch (module_ir.types.get(function.return_type)) {
            .struct_ => |struct_id| {
                const struct_def = module_ir.structs.items[struct_id];
                for (struct_def.fields.items) |field| {
                    if (count >= MAX_INTER_STAGE_VARS) break;
                    const io = field.io orelse continue;
                    // Skip builtins like @builtin(position) — they are not user inter-stage vars.
                    if (io.builtin != .none and io.location == null) continue;
                    vars_buf[count] = .{
                        .location = io.location orelse 0,
                        .interpolation = io.interpolation,
                        .builtin = io.builtin,
                    };
                    count += 1;
                }
            },
            else => {
                // Non-struct return with IO attr (e.g. @location(0) vec4f).
                if (function.return_io) |io| {
                    if (count < MAX_INTER_STAGE_VARS and (io.builtin == .none or io.location != null)) {
                        vars_buf[count] = .{
                            .location = io.location orelse 0,
                            .interpolation = io.interpolation,
                            .builtin = io.builtin,
                        };
                        count += 1;
                    }
                }
            },
        }
    }

    if (count == 0) return &.{};
    return allocator.dupe(InterStageVar, vars_buf[0..count]) catch return analysis.TranslateError.OutOfMemory;
}

pub fn translateToSpirvForGraphicsRuntime(allocator: std.mem.Allocator, wgsl: []const u8) analysis.TranslateError!GraphicsTranslationResult {
    return translateToSpirvForGraphicsRuntimeWithDiagnostic(allocator, wgsl, analysis.compatibilityDiagnostic());
}
