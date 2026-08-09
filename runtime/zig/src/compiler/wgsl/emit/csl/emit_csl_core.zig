// emit_csl_core.zig — Core CSL emitter: classifies the kernel and dispatches
// to the appropriate template emitter.
//
// Output format: a single buffer containing two sections separated by
// `//--- <filename> ---` markers. The host or build tool splits on these
// markers to produce the layout.csl and pe_program.csl files that `cslc`
// expects.
//
// Pipeline:
//   ir.Module → classify → layout emitter + PE program emitter → buffer

const ir = @import("../../ir/ir.zig");
const spec = @import("csl_spec.zig");
const classify = @import("emit_csl_classify.zig");
const validate = @import("emit_csl_validate.zig");
const layout = @import("emit_csl_layout.zig");
const elementwise = @import("emit_csl_elementwise.zig");
const reduction = @import("emit_csl_reduction.zig");
const matmul = @import("emit_csl_matmul.zig");
const matmul_q4k = @import("emit_csl_matmul_q4k.zig");
const reduce_dist = @import("emit_csl_reduce_dist.zig");
const attention = @import("emit_csl_attention.zig");
const linear_attn = @import("emit_csl_linear_attn.zig");
const kv_cache = @import("emit_csl_kv_cache.zig");
const gather = @import("emit_csl_gather.zig");
const rope = @import("emit_csl_rope.zig");
const dequant = @import("emit_csl_dequant.zig");
const sample = @import("emit_csl_sample.zig");
const fused = @import("emit_csl_fused.zig");
const fused_ffn = @import("emit_csl_fused_ffn.zig");
const text_buffer = @import("csl_text_buffer.zig");

const write = text_buffer.write;

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
    UnsupportedConstruct,
    UnsupportedPattern,
};

pub const MAX_OUTPUT: usize = 512 * 1024;

pub fn emit(module: *const ir.Module, out: []u8) EmitError!usize {
    var pos: usize = 0;

    // CSL only supports compute shaders.
    if (module.entry_points.items.len == 0) {
        return error.InvalidIr;
    }

    // Process the first compute entry point (CSL programs have one kernel).
    const entry = module.entry_points.items[0];
    if (entry.stage != .compute) {
        return error.UnsupportedConstruct;
    }

    // Classify the kernel pattern.
    const pattern = classify.classify(module, entry);
    if (!classify.patternContractValid(pattern)) {
        return error.UnsupportedPattern;
    }

    // Emit layout section.
    try writeSection(out, &pos, spec.LAYOUT_FILENAME);
    try emitLayout(out, &pos, module, entry, pattern);

    // Emit PE program section.
    try writeSection(out, &pos, spec.PE_PROGRAM_FILENAME);
    try emitPeProgram(out, &pos, module, entry, pattern);

    const validation_pattern = patternToValidationKind(pattern) catch return error.UnsupportedPattern;
    const validation = validate.validatePattern(out[0..pos], validation_pattern);
    if (!validation.valid) {
        return error.InvalidIr;
    }

    return pos;
}

fn patternToValidationKind(pattern: classify.KernelPattern) EmitError!validate.PatternKind {
    return switch (pattern) {
        .element_wise => .element_wise,
        .reduction => .reduction,
        .tiled_matmul => .tiled_matmul,
        .tiled_matmul_q4k_dequant_b => .tiled_matmul_q4k_dequant_b,
        .gather => .gather,
        .rope => .rope,
        .attention_streaming => .attention_streaming,
        .attention_decode => .attention_decode,
        .attention_tiled => .attention_tiled,
        .attention_linear => .attention_linear,
        .dequant => .dequant,
        .sample => .sample,
        .fused_gemv_dequant => .fused_gemv_dequant,
        .kv_write => .kv_write,
        .kv_read => .kv_read,
        .fused_ffn => .fused_ffn,
        .unsupported => return error.UnsupportedPattern,
    };
}

fn emitLayout(
    out: []u8,
    pos: *usize,
    module: *const ir.Module,
    entry: ir.EntryPoint,
    pattern: classify.KernelPattern,
) EmitError!void {
    switch (pattern) {
        .element_wise => |info| try layout.emitElementWiseLayout(out, pos, module, entry, info),
        .reduction => |info| {
            if (info.distributed) {
                try reduce_dist.emitDistributedLayout(out, pos, module);
            } else {
                try layout.emitReductionLayout(out, pos, module, entry, info);
            }
        },
        .tiled_matmul => |info| try layout.emitMatmulLayout(out, pos, module, entry, info),
        .tiled_matmul_q4k_dequant_b => |info| try layout.emitMatmulQ4kLayout(out, pos, module, entry, info),
        .gather => |info| try layout.emitGatherLayout(out, pos, module, info),
        .rope => |info| try layout.emitRoPELayout(out, pos, module, info),
        .dequant => |info| try layout.emitDequantLayout(out, pos, module, info),
        .sample => |info| try layout.emitSampleLayout(out, pos, module, info),
        .fused_gemv_dequant => |info| try layout.emitFusedGemvLayout(out, pos, module, info),
        .attention_streaming => |info| try layout.emitStreamingAttentionLayout(out, pos, module, info),
        .attention_decode => |info| try layout.emitDecodeAttentionLayout(out, pos, module, info),
        .attention_tiled => |info| try layout.emitTiledAttentionLayout(out, pos, module, info),
        .attention_linear => |info| try layout.emitLinearAttentionLayout(out, pos, module, info),
        .kv_write => |info| try layout.emitKvWriteLayout(out, pos, module, info),
        .kv_read => |info| try layout.emitKvReadLayout(out, pos, module, info),
        .fused_ffn => |info| try layout.emitFusedFfnLayout(out, pos, module, info),
        .unsupported => return error.UnsupportedPattern,
    }
}

fn emitPeProgram(
    out: []u8,
    pos: *usize,
    module: *const ir.Module,
    entry: ir.EntryPoint,
    pattern: classify.KernelPattern,
) EmitError!void {
    switch (pattern) {
        .element_wise => |info| try elementwise.emit(out, pos, module, entry, info),
        .reduction => |info| {
            if (info.distributed) {
                try reduce_dist.emitDistributed(out, pos, module);
            } else {
                try reduction.emit(out, pos, module, entry, info);
            }
        },
        .tiled_matmul => |info| try matmul.emit(out, pos, module, entry, info),
        .tiled_matmul_q4k_dequant_b => |info| try matmul_q4k.emit(out, pos, module, entry, info),
        .gather => |info| try gather.emit(out, pos, module, info),
        .rope => |info| try rope.emit(out, pos, module, info),
        .dequant => |info| try dequant.emit(out, pos, module, info),
        .sample => |info| try sample.emit(out, pos, module, info),
        .fused_gemv_dequant => |info| try fused.emit(out, pos, module, info),
        .attention_streaming => |info| try attention.emitStreaming(out, pos, module, info),
        .attention_decode => |info| try attention.emitDecode(out, pos, module, info),
        .attention_tiled => |info| try attention.emitTiled(out, pos, module, info),
        .attention_linear => |info| try linear_attn.emit(out, pos, module, info),
        .kv_write => |info| try kv_cache.emitWrite(out, pos, module, info),
        .kv_read => |info| try kv_cache.emitRead(out, pos, module, info),
        .fused_ffn => |info| try fused_ffn.emit(out, pos, module, info),
        .unsupported => return error.UnsupportedPattern,
    }
}

fn writeSection(buf: []u8, pos: *usize, filename: []const u8) EmitError!void {
    try write(buf, pos, spec.SECTION_SEPARATOR);
    try write(buf, pos, filename);
    try write(buf, pos, spec.SECTION_SEPARATOR_END);
}
