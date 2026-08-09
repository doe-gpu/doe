const std = @import("std");

const mod = @import("../../mod.zig");
const classify = @import("emit_csl_classify.zig");
const layout = @import("emit_csl_layout.zig");
const elementwise = @import("emit_csl_elementwise.zig");
const reduction = @import("emit_csl_reduction.zig");
const matmul = @import("emit_csl_matmul.zig");
const matmul_q4k = @import("emit_csl_matmul_q4k.zig");
const attention = @import("emit_csl_attention.zig");
const linear_attn = @import("emit_csl_linear_attn.zig");
const kv_cache = @import("emit_csl_kv_cache.zig");
const gather = @import("emit_csl_gather.zig");
const rope = @import("emit_csl_rope.zig");
const dequant = @import("emit_csl_dequant.zig");
const sample = @import("emit_csl_sample.zig");
const fused = @import("emit_csl_fused.zig");
const fused_ffn = @import("emit_csl_fused_ffn.zig");
const dense_gemv = @import("emit_csl_dense_gemv.zig");
const semantic_ops = @import("emit_csl_semantic_ops.zig");
const rmsnorm_pack = @import("emit_csl_rmsnorm_pack.zig");
const rewrite = @import("emit_csl_host_compile_rewrite.zig");
const validate = @import("emit_csl_validate.zig");
const spec = @import("csl_spec.zig");
const ir = @import("../../ir/ir.zig");
const text_buffer = @import("csl_text_buffer.zig");

const write = text_buffer.write;

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
    UnsupportedConstruct,
    UnsupportedPattern,
    InvalidWgsl,
    DuplicateSymbol,
    InvalidAttribute,
    InvalidType,
    OutOfMemory,
    ShaderToolchainUnavailable,
    UnexpectedToken,
    TypeMismatch,
    UnknownIdentifier,
    UnknownType,
    UnsupportedWgsl,
};

pub const CompileSourceSections = struct {
    combined: []const u8,
    layout: []const u8,
    pe_program: []const u8,
};

pub fn emitPatternSections(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    out: []u8,
) EmitError!CompileSourceSections {
    return emitPatternSectionsForElem(allocator, pattern, .f32, out);
}

pub fn emitPatternSectionsForElem(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    elem: ir.ScalarType,
    out: []u8,
) EmitError!CompileSourceSections {
    if (std.mem.eql(u8, pattern, "dense_gemv")) {
        return emitDenseGemvSections(out);
    }
    const semantic_pattern = semanticPatternAlias(pattern);
    if (semantic_ops.isSemanticPattern(semantic_pattern)) {
        return emitSemanticPatternSectionsForElem(semantic_pattern, elem, out);
    }

    const source = patternSource(pattern) orelse return error.UnsupportedPattern;
    var module_ir = try mod.analyzeToIr(allocator, source);
    defer module_ir.deinit();

    if (module_ir.entry_points.items.len == 0) return error.InvalidIr;
    const entry = module_ir.entry_points.items[0];
    if (entry.stage != .compute) return error.UnsupportedConstruct;

    var pos: usize = 0;
    const pattern_info = try resolvePattern(pattern, &module_ir, entry);

    try writeSection(out, &pos, spec.LAYOUT_FILENAME);
    try emitLayout(out, &pos, &module_ir, entry, pattern_info);

    try writeSection(out, &pos, spec.PE_PROGRAM_FILENAME);
    try emitPeProgram(out, &pos, &module_ir, entry, pattern_info, elem);

    const validation_kind = try validationKind(pattern);
    if (elem == .f16) {
        try rewrite.rewriteF16CompileSourceInPlace(out, &pos);
        if (std.mem.eql(u8, pattern, "fused_gemv_dequant")) {
            try rewrite.restoreFusedGemvF32ReductionInPlace(out, &pos);
        }
    }
    const validation = validate.validatePattern(out[0..pos], validation_kind);
    if (!validation.valid) return error.InvalidIr;

    const combined = out[0..pos];
    return .{
        .combined = combined,
        .layout = sectionBody(combined, spec.LAYOUT_FILENAME) orelse return error.InvalidIr,
        .pe_program = sectionBody(combined, spec.PE_PROGRAM_FILENAME) orelse return error.InvalidIr,
    };
}

fn emitDenseGemvSections(out: []u8) EmitError!CompileSourceSections {
    var pos: usize = 0;

    try writeSection(out, &pos, spec.LAYOUT_FILENAME);
    try dense_gemv.emitLayout(out, &pos);

    try writeSection(out, &pos, spec.PE_PROGRAM_FILENAME);
    try dense_gemv.emitPeProgram(out, &pos);

    const validation = validate.validatePattern(out[0..pos], .dense_gemv);
    if (!validation.valid) return error.InvalidIr;
    const combined = out[0..pos];
    return .{
        .combined = combined,
        .layout = sectionBody(combined, spec.LAYOUT_FILENAME) orelse return error.InvalidIr,
        .pe_program = sectionBody(combined, spec.PE_PROGRAM_FILENAME) orelse return error.InvalidIr,
    };
}

fn emitSemanticPatternSections(pattern: []const u8, out: []u8) EmitError!CompileSourceSections {
    return emitSemanticPatternSectionsForElem(pattern, .f32, out);
}

fn semanticPatternAlias(pattern: []const u8) []const u8 {
    if (std.mem.eql(u8, pattern, "residual")) return "residual_add";
    return pattern;
}

fn emitSemanticPatternSectionsForElem(
    pattern: []const u8,
    elem: ir.ScalarType,
    out: []u8,
) EmitError!CompileSourceSections {
    var pos: usize = 0;

    try writeSection(out, &pos, spec.LAYOUT_FILENAME);
    try semantic_ops.emitLayout(out, &pos, pattern);

    try writeSection(out, &pos, spec.PE_PROGRAM_FILENAME);
    try semantic_ops.emitPeProgram(out, &pos, pattern);

    if (elem == .f16) {
        try rewrite.rewriteF16CompileSourceInPlace(out, &pos);
        if (std.mem.eql(u8, pattern, "rms_norm")) {
            try rmsnorm_pack.rewriteF16OutputPackInPlace(out, &pos);
        } else if (std.mem.eql(u8, pattern, "residual_add") or
            isGatedSemanticPattern(pattern))
        {
            try rmsnorm_pack.rewriteF16OutputPackInPlaceForExtent(out, &pos, "chunk_size");
        }
    }
    const combined = out[0..pos];
    return .{
        .combined = combined,
        .layout = sectionBody(combined, spec.LAYOUT_FILENAME) orelse return error.InvalidIr,
        .pe_program = sectionBody(combined, spec.PE_PROGRAM_FILENAME) orelse return error.InvalidIr,
    };
}

fn resolvePattern(pattern: []const u8, module_ir: *const ir.Module, entry: ir.EntryPoint) EmitError!classify.KernelPattern {
    if (std.mem.eql(u8, pattern, "kv_read")) {
        return .{ .kv_read = .{
            .key_cache_global = 0,
            .val_cache_global = 1,
            .key_out_global = 2,
            .val_out_global = 3,
        } };
    }
    if (std.mem.eql(u8, pattern, "fused_ffn")) {
        return .{ .fused_ffn = .{
            .input_global = 0,
            .gate_weight_global = 1,
            .up_weight_global = 2,
            .output_global = 3,
            .input_count = 3,
            .output_count = 1,
        } };
    }

    const detected = classify.classify(module_ir, entry);
    if (!classify.patternContractValid(detected)) return error.UnsupportedPattern;

    switch (detected) {
        .element_wise => if (isElementWisePattern(pattern)) return detected,
        .reduction => if (std.mem.eql(u8, pattern, "reduction")) return detected,
        .tiled_matmul => if (std.mem.eql(u8, pattern, "tiled_matmul")) return detected,
        .tiled_matmul_q4k_dequant_b => if (std.mem.eql(u8, pattern, "tiled_matmul_q4k_dequant_b")) return detected,
        .gather => if (std.mem.eql(u8, pattern, "gather")) return detected,
        .rope => if (std.mem.eql(u8, pattern, "rope")) return detected,
        .attention_streaming => if (std.mem.eql(u8, pattern, "attention_streaming")) return detected,
        .attention_decode => if (std.mem.eql(u8, pattern, "attention_decode")) return detected,
        .attention_tiled => if (std.mem.eql(u8, pattern, "attention_tiled")) return detected,
        .dequant => if (std.mem.eql(u8, pattern, "dequant")) return detected,
        .sample => if (std.mem.eql(u8, pattern, "sample")) return detected,
        .fused_gemv_dequant => if (std.mem.eql(u8, pattern, "fused_gemv_dequant")) return detected,
        .attention_linear => if (std.mem.eql(u8, pattern, "attention_linear")) return detected,
        .kv_write => if (std.mem.eql(u8, pattern, "kv_write")) return detected,
        .fused_ffn => if (std.mem.eql(u8, pattern, "fused_ffn")) return detected,
        .kv_read, .unsupported => {},
    }
    return error.InvalidIr;
}

fn emitLayout(
    out: []u8,
    pos: *usize,
    module_ir: *const ir.Module,
    entry: ir.EntryPoint,
    pattern: classify.KernelPattern,
) EmitError!void {
    switch (pattern) {
        .element_wise => |info| try layout.emitElementWiseLayout(out, pos, module_ir, entry, info),
        .reduction => |info| try layout.emitReductionLayout(out, pos, module_ir, entry, info),
        .tiled_matmul => |info| try layout.emitMatmulLayout(out, pos, module_ir, entry, info),
        .tiled_matmul_q4k_dequant_b => |info| try layout.emitMatmulQ4kLayout(out, pos, module_ir, entry, info),
        .gather => |info| try layout.emitGatherLayout(out, pos, module_ir, info),
        .rope => |info| try layout.emitRoPELayout(out, pos, module_ir, info),
        .attention_streaming => |info| try layout.emitStreamingAttentionLayout(out, pos, module_ir, info),
        .attention_decode => |info| try layout.emitDecodeAttentionLayout(out, pos, module_ir, info),
        .attention_tiled => |info| try layout.emitTiledAttentionLayout(out, pos, module_ir, info),
        .dequant => |info| try layout.emitDequantLayout(out, pos, module_ir, info),
        .sample => |info| try layout.emitSampleLayout(out, pos, module_ir, info),
        .fused_gemv_dequant => |info| try layout.emitFusedGemvLayout(out, pos, module_ir, info),
        .attention_linear => |info| try layout.emitLinearAttentionLayout(out, pos, module_ir, info),
        .kv_write => |info| try layout.emitKvWriteLayout(out, pos, module_ir, info),
        .kv_read => |info| try layout.emitKvReadLayout(out, pos, module_ir, info),
        .fused_ffn => |info| try layout.emitFusedFfnLayout(out, pos, module_ir, info),
        .unsupported => return error.UnsupportedPattern,
    }
}

fn emitPeProgram(
    out: []u8,
    pos: *usize,
    module_ir: *const ir.Module,
    entry: ir.EntryPoint,
    pattern: classify.KernelPattern,
    elem: ir.ScalarType,
) EmitError!void {
    switch (pattern) {
        .element_wise => |info| try elementwise.emit(out, pos, module_ir, entry, info),
        .reduction => |info| try reduction.emit(out, pos, module_ir, entry, info),
        .tiled_matmul => |info| try matmul.emit(out, pos, module_ir, entry, info),
        .tiled_matmul_q4k_dequant_b => |info| try matmul_q4k.emit(out, pos, module_ir, entry, info),
        .gather => |info| try gather.emit(out, pos, module_ir, info),
        .rope => |info| try rope.emit(out, pos, module_ir, info),
        .attention_streaming => |info| try attention.emitStreaming(out, pos, module_ir, info),
        .attention_decode => |info| try attention.emitDecode(out, pos, module_ir, info),
        .attention_tiled => |info| try attention.emitTiled(out, pos, module_ir, info),
        .dequant => |info| try dequant.emit(out, pos, module_ir, info),
        .sample => |info| try sample.emit(out, pos, module_ir, info),
        .fused_gemv_dequant => |info| try fused.emitForElem(out, pos, module_ir, info, elem),
        .attention_linear => |info| try linear_attn.emit(out, pos, module_ir, info),
        .kv_write => |info| try kv_cache.emitWrite(out, pos, module_ir, info),
        .kv_read => |info| try kv_cache.emitRead(out, pos, module_ir, info),
        .fused_ffn => |info| try fused_ffn.emit(out, pos, module_ir, info),
        .unsupported => return error.UnsupportedPattern,
    }
}

fn validationKind(pattern: []const u8) EmitError!validate.PatternKind {
    if (isElementWisePattern(pattern)) return .element_wise;
    if (std.mem.eql(u8, pattern, "reduction")) return .reduction;
    if (std.mem.eql(u8, pattern, "tiled_matmul")) return .tiled_matmul;
    if (std.mem.eql(u8, pattern, "tiled_matmul_q4k_dequant_b")) return .tiled_matmul_q4k_dequant_b;
    if (std.mem.eql(u8, pattern, "gather")) return .gather;
    if (std.mem.eql(u8, pattern, "rope")) return .rope;
    if (std.mem.eql(u8, pattern, "attention_streaming")) return .attention_streaming;
    if (std.mem.eql(u8, pattern, "attention_decode")) return .attention_decode;
    if (std.mem.eql(u8, pattern, "attention_tiled")) return .attention_tiled;
    if (std.mem.eql(u8, pattern, "attention_linear")) return .attention_linear;
    if (std.mem.eql(u8, pattern, "dequant")) return .dequant;
    if (std.mem.eql(u8, pattern, "sample")) return .sample;
    if (std.mem.eql(u8, pattern, "fused_gemv_dequant")) return .fused_gemv_dequant;
    if (std.mem.eql(u8, pattern, "dense_gemv")) return .dense_gemv;
    if (std.mem.eql(u8, pattern, "kv_write")) return .kv_write;
    if (std.mem.eql(u8, pattern, "kv_read")) return .kv_read;
    if (std.mem.eql(u8, pattern, "fused_ffn")) return .fused_ffn;
    return error.UnsupportedPattern;
}

pub fn patternSource(pattern: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, pattern, "element_wise")) return ELEMENT_WISE_WGSL;
    if (std.mem.eql(u8, pattern, "residual")) return RESIDUAL_WGSL;
    if (std.mem.eql(u8, pattern, "gelu")) return GELU_WGSL;
    if (std.mem.eql(u8, pattern, "reduction")) return REDUCTION_WGSL;
    if (std.mem.eql(u8, pattern, "tiled_matmul")) return TILED_MATMUL_WGSL;
    if (std.mem.eql(u8, pattern, "gather")) return GATHER_WGSL;
    if (std.mem.eql(u8, pattern, "rope")) return ROPE_WGSL;
    if (std.mem.eql(u8, pattern, "attention_streaming")) return ATTENTION_STREAMING_WGSL;
    if (std.mem.eql(u8, pattern, "attention_decode")) return ATTENTION_DECODE_WGSL;
    if (std.mem.eql(u8, pattern, "attention_tiled")) return ATTENTION_TILED_WGSL;
    if (std.mem.eql(u8, pattern, "attention_linear")) return ATTENTION_LINEAR_WGSL;
    if (std.mem.eql(u8, pattern, "dequant")) return DEQUANT_WGSL;
    if (std.mem.eql(u8, pattern, "sample")) return SAMPLE_WGSL;
    if (std.mem.eql(u8, pattern, "fused_gemv_dequant")) return FUSED_GEMV_DEQUANT_WGSL;
    if (std.mem.eql(u8, pattern, "kv_write")) return KV_WRITE_WGSL;
    if (std.mem.eql(u8, pattern, "kv_read")) return KV_READ_WGSL;
    if (std.mem.eql(u8, pattern, "fused_ffn")) return FUSED_FFN_WGSL;
    return null;
}

fn isElementWisePattern(pattern: []const u8) bool {
    return std.mem.eql(u8, pattern, "element_wise") or
        std.mem.eql(u8, pattern, "residual") or
        std.mem.eql(u8, pattern, "gelu");
}

fn isGatedSemanticPattern(pattern: []const u8) bool {
    return std.mem.eql(u8, pattern, "gelu_gated") or
        std.mem.eql(u8, pattern, "silu_gated") or
        std.mem.eql(u8, pattern, "sigmoid_gated");
}

pub fn sectionBody(csl: []const u8, filename: []const u8) ?[]const u8 {
    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrint(
        &marker_buf,
        "{s}{s}{s}",
        .{ spec.SECTION_SEPARATOR, filename, spec.SECTION_SEPARATOR_END },
    ) catch return null;

    const header_index = std.mem.indexOf(u8, csl, marker) orelse return null;
    const body_start = header_index + marker.len;
    const next_header = std.mem.indexOfPos(u8, csl, body_start, spec.SECTION_SEPARATOR) orelse csl.len;
    return csl[body_start..next_header];
}

fn writeSection(buf: []u8, pos: *usize, filename: []const u8) EmitError!void {
    try write(buf, pos, spec.SECTION_SEPARATOR);
    try write(buf, pos, filename);
    try write(buf, pos, spec.SECTION_SEPARATOR_END);
}

const ELEMENT_WISE_WGSL =
    \\struct Uniforms {
    \\    size: u32,
    \\}
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\@group(0) @binding(1) var<storage, read> input: array<f32>;
    \\@group(0) @binding(2) var<storage, read_write> output: array<f32>;
    \\@compute @workgroup_size(256)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    let idx = gid.x;
    \\    if (idx >= u.size) { return; }
    \\    output[idx] = input[idx] * 1.0;
    \\}
;

const RESIDUAL_WGSL =
    \\@group(0) @binding(0) var<storage, read> input: array<f32>;
    \\@group(0) @binding(1) var<storage, read> residual: array<f32>;
    \\@group(0) @binding(2) var<storage, read_write> output: array<f32>;
    \\@compute @workgroup_size(256)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    let idx = gid.x;
    \\    output[idx] = input[idx] + residual[idx];
    \\}
;

const GELU_WGSL =
    \\@group(0) @binding(0) var<storage, read> input: array<f32>;
    \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
    \\@compute @workgroup_size(256)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    let idx = gid.x;
    \\    let x = input[idx];
    \\    let t = 0.7978845608 * (x + 0.044715 * x * x * x);
    \\    output[idx] = 0.5 * x * (1.0 + tanh(t));
    \\}
;

// Real RMSNorm: y = (x / sqrt(mean(x^2) + eps)) * scale
// where scale = (1 + weight) when rms_norm_offset != 0 (Gemma) else weight.
//
// Single-barrier shape: 64-lane chunked sum-of-squares pre-barrier; thread 0
// post-barrier folds the 64 partials, computes inv_rms, then writes the full
// hidden_size output applying weight per element. Doe's emit_csl_reduction.zig
// auto-lowers this single-barrier WGSL into single-PE CSL where the
// pre-barrier work runs as a per-lane for-loop and the post-barrier work runs
// once with lid.x folded to 0. Each PE handles one token's full hidden vector.
//
// Reference: doppler/src/gpu/kernels/rmsnorm.wgsl (main_small entry point);
// the chunked-sum + per-element output pattern matches this kernel's
// `for (i in 0..elements_per_thread)` then `for (i in 0..size)` shape.
const REDUCTION_WGSL =
    \\struct Uniforms {
    \\    size: u32,
    \\    eps: f32,
    \\    rms_norm_offset: u32,
    \\    _pad: u32,
    \\}
    \\@group(0) @binding(0) var<uniform> u: Uniforms;
    \\@group(0) @binding(1) var<storage, read> input: array<f32>;
    \\@group(0) @binding(2) var<storage, read> weight: array<f32>;
    \\@group(0) @binding(3) var<storage, read_write> output: array<f32>;
    \\var<workgroup> partial: array<f32, 64>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(local_invocation_id) lid: vec3u, @builtin(global_invocation_id) gid: vec3u) {
    \\    let size = u.size;
    \\    let elements_per_lane = (size + 63u) / 64u;
    \\    let lane_start = lid.x * elements_per_lane;
    \\    var lane_end: u32 = lane_start + elements_per_lane;
    \\    if (lane_end > size) { lane_end = size; }
    \\    var local_sum: f32 = 0.0;
    \\    for (var i: u32 = lane_start; i < lane_end; i = i + 1u) {
    \\        let x = input[i];
    \\        local_sum = local_sum + x * x;
    \\    }
    \\    partial[lid.x] = local_sum;
    \\    workgroupBarrier();
    \\    if (lid.x == 0u) {
    \\        var sum: f32 = 0.0;
    \\        for (var i: u32 = 0u; i < 64u; i = i + 1u) {
    \\            sum = sum + partial[i];
    \\        }
    \\        let mean_sq = sum / f32(size);
    \\        let inv_rms = 1.0 / sqrt(mean_sq + u.eps);
    \\        let use_offset: bool = u.rms_norm_offset != 0u;
    \\        for (var i: u32 = 0u; i < size; i = i + 1u) {
    \\            let x = input[i];
    \\            let w = weight[i];
    \\            var scale: f32 = w;
    \\            if (use_offset) { scale = 1.0 + w; }
    \\            output[i] = x * inv_rms * scale;
    \\        }
    \\    }
    \\}
;

const TILED_MATMUL_WGSL =
    \\@group(0) @binding(0) var<storage, read> a: array<f32>;
    \\@group(0) @binding(1) var<storage, read> b: array<f32>;
    \\@group(0) @binding(2) var<storage, read_write> c: array<f32>;
    \\var<workgroup> tile_a: array<f32, 64>;
    \\var<workgroup> tile_b: array<f32, 64>;
    \\@compute @workgroup_size(8, 8, 1)
    \\fn main(@builtin(local_invocation_id) lid: vec3u, @builtin(global_invocation_id) gid: vec3u) {
    \\    tile_a[lid.x] = a[gid.x];
    \\    tile_b[lid.y] = b[gid.y];
    \\    workgroupBarrier();
    \\    var acc: f32 = 0.0;
    \\    for (var k: u32 = 0u; k < 8u; k = k + 1u) {
    \\        acc = acc + tile_a[k] * tile_b[k];
    \\    }
    \\    c[gid.x] = acc;
    \\}
;

const GATHER_WGSL =
    \\@group(0) @binding(0) var<storage, read> indices: array<u32>;
    \\@group(0) @binding(1) var<storage, read> table: array<f32>;
    \\@group(0) @binding(2) var<storage, read_write> output: array<f32>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    let token = indices[gid.x];
    \\    output[gid.x] = table[token];
    \\}
;

const ROPE_WGSL =
    \\@group(0) @binding(0) var<storage, read_write> input: array<f32>;
    \\@group(0) @binding(1) var<storage, read> cos_table: array<f32>;
    \\@group(0) @binding(2) var<storage, read> sin_table: array<f32>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    let x = input[gid.x];
    \\    input[gid.x] = x * cos_table[gid.x] - x * sin_table[gid.x];
    \\}
;

const ATTENTION_LINEAR_WGSL =
    \\@group(0) @binding(0) var<storage, read> query: array<f32>;
    \\@group(0) @binding(1) var<storage, read> key: array<f32>;
    \\@group(0) @binding(2) var<storage, read> val: array<f32>;
    \\@group(0) @binding(3) var<storage, read_write> output: array<f32>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    output[gid.x] = query[gid.x] * key[gid.x] + val[gid.x];
    \\}
;

const ATTENTION_STREAMING_WGSL =
    \\@group(0) @binding(0) var<storage, read> query: array<f32>;
    \\@group(0) @binding(1) var<storage, read> key: array<f32>;
    \\@group(0) @binding(2) var<storage, read> val: array<f32>;
    \\@group(0) @binding(3) var<storage, read_write> output: array<f32>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    let score = exp(query[gid.x] * key[gid.x]);
    \\    output[gid.x] = score * val[gid.x];
    \\}
;

const ATTENTION_DECODE_WGSL =
    \\@group(0) @binding(0) var<storage, read> query: array<f32>;
    \\@group(0) @binding(1) var<storage, read> key: array<f32>;
    \\@group(0) @binding(2) var<storage, read> val: array<f32>;
    \\@group(0) @binding(3) var<storage, read_write> output: array<f32>;
    \\var<workgroup> partial: array<f32, 64>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(local_invocation_id) lid: vec3u, @builtin(global_invocation_id) gid: vec3u) {
    \\    partial[lid.x] = query[gid.x] * key[gid.x];
    \\    workgroupBarrier();
    \\    if (lid.x == 0u) {
    \\        output[gid.x] = partial[0] * val[gid.x];
    \\    }
    \\}
;

const ATTENTION_TILED_WGSL =
    \\@group(0) @binding(0) var<storage, read> query: array<f32>;
    \\@group(0) @binding(1) var<storage, read> key: array<f32>;
    \\@group(0) @binding(2) var<storage, read> val: array<f32>;
    \\@group(0) @binding(3) var<storage, read_write> output: array<f32>;
    \\var<workgroup> shared_k: array<f32, 64>;
    \\var<workgroup> shared_v: array<f32, 64>;
    \\var<workgroup> shared_scores: array<f32, 64>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(local_invocation_id) lid: vec3u, @builtin(global_invocation_id) gid: vec3u) {
    \\    shared_k[lid.x] = key[gid.x];
    \\    shared_v[lid.x] = val[gid.x];
    \\    shared_scores[lid.x] = query[gid.x] * key[gid.x];
    \\    workgroupBarrier();
    \\    output[gid.x] = shared_scores[lid.x] * shared_v[lid.x];
    \\}
;

const DEQUANT_WGSL =
    \\struct Q4Block {
    \\    packed: u32,
    \\}
    \\@group(0) @binding(0) var<storage, read> quant: array<Q4Block>;
    \\@group(0) @binding(1) var<storage, read_write> output: array<f32>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    output[gid.x] = f32(quant[0].packed);
    \\}
;

const SAMPLE_WGSL =
    \\@group(0) @binding(0) var<storage, read> logits: array<f32>;
    \\@group(0) @binding(1) var<storage, read_write> tokens: array<u32>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    tokens[0] = gid.x;
    \\    _ = logits[gid.x];
    \\}
;

const FUSED_GEMV_DEQUANT_WGSL =
    \\struct Q4Block {
    \\    packed: u32,
    \\}
    \\@group(0) @binding(0) var<storage, read> activation: array<f32>;
    \\@group(0) @binding(1) var<storage, read> weight: array<Q4Block>;
    \\@group(0) @binding(2) var<storage, read_write> output: array<f32>;
    \\var<workgroup> partial: array<f32, 64>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(local_invocation_id) lid: vec3u, @builtin(global_invocation_id) gid: vec3u) {
    \\    partial[lid.x] = activation[gid.x] + f32(weight[0].packed);
    \\    workgroupBarrier();
    \\    if (lid.x == 0u) {
    \\        output[gid.x] = partial[0];
    \\    }
    \\}
;

const KV_WRITE_WGSL =
    \\@group(0) @binding(0) var<storage, read> key_proj: array<f32>;
    \\@group(0) @binding(1) var<storage, read> val_proj: array<f32>;
    \\@group(0) @binding(2) var<storage, read_write> key_cache: array<f32>;
    \\@group(0) @binding(3) var<storage, read_write> val_cache: array<f32>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    key_cache[gid.x] = key_proj[gid.x];
    \\    val_cache[gid.x] = val_proj[gid.x];
    \\}
;

const KV_READ_WGSL =
    \\@group(0) @binding(0) var<storage, read> key_cache: array<f32>;
    \\@group(0) @binding(1) var<storage, read> val_cache: array<f32>;
    \\@group(0) @binding(2) var<storage, read_write> key_out: array<f32>;
    \\@group(0) @binding(3) var<storage, read_write> val_out: array<f32>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(global_invocation_id) gid: vec3u) {
    \\    key_out[gid.x] = key_cache[gid.x];
    \\    val_out[gid.x] = val_cache[gid.x];
    \\}
;

const FUSED_FFN_WGSL =
    \\@group(0) @binding(0) var<storage, read> input: array<f32>;
    \\@group(0) @binding(1) var<storage, read> gate_weight: array<f32>;
    \\@group(0) @binding(2) var<storage, read> up_weight: array<f32>;
    \\@group(0) @binding(3) var<storage, read_write> output: array<f32>;
    \\var<workgroup> partial: array<f32, 64>;
    \\@compute @workgroup_size(64)
    \\fn main(@builtin(local_invocation_id) lid: vec3u, @builtin(global_invocation_id) gid: vec3u) {
    \\    partial[lid.x] = input[gid.x] * gate_weight[gid.x] + up_weight[gid.x];
    \\    workgroupBarrier();
    \\    if (lid.x == 0u) {
    \\        output[gid.x] = partial[0];
    \\    }
    \\}
;

test "host compile source emits known HostPlan CSL families" {
    const patterns = [_][]const u8{
        "element_wise",
        "reduction",
        "tiled_matmul",
        "gather",
        "rope",
        "attention_streaming",
        "attention_decode",
        "attention_tiled",
        "attention_linear",
        "dequant",
        "sample",
        "fused_gemv_dequant",
        "kv_write",
        "kv_read",
        "fused_ffn",
        "residual",
        "gelu",
        "rms_norm",
        "residual_add",
        "gelu_gated",
    };

    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;
    for (patterns) |pattern| {
        const sections = try emitPatternSections(std.testing.allocator, pattern, &buf);
        try std.testing.expect(sections.combined.len > 0);
        try std.testing.expect(sections.layout.len > 0);
        try std.testing.expect(sections.pe_program.len > 0);
        try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@set_rectangle") != null);
        try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "@export_symbol(compute)") != null);
    }
}

test "host compile source routes af16 lane into f16 CSL source" {
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;

    const rms = try emitPatternSectionsForElem(std.testing.allocator, "rms_norm", .f16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, rms.layout, "@export_name(\"input\", [*]f16, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rms.layout, "@export_name(\"output\", [*]f16, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rms.layout, "@export_name(\"output_chunk_0000\", [*]u32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rms.pe_program, "[hidden_size]f16") != null);
    try std.testing.expect(std.mem.indexOf(u8, rms.pe_program, "output_chunk_0000_ptr: [*]u32 = &output_chunk_0000;") != null);
    try std.testing.expect(std.mem.indexOf(u8, rms.combined, "f32") == null);

    const gated = try emitPatternSectionsForElem(std.testing.allocator, "gelu_gated", .f16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, gated.layout, "@export_name(\"output_chunk_0000\", [*]u32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated.pe_program, "[chunk_size]f16") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated.pe_program, "output_chunk_0000_ptr: [*]u32 = &output_chunk_0000;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated.pe_program, "base + 1 < @as(u32, chunk_size)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated.combined, "f32") == null);

    const residual = try emitPatternSectionsForElem(std.testing.allocator, "residual", .f16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, residual.layout, "@export_name(\"output_chunk_0000\", [*]u32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, residual.pe_program, "[chunk_size]f16") != null);
    try std.testing.expect(std.mem.indexOf(u8, residual.pe_program, "output_chunk_0000_ptr: [*]u32 = &output_chunk_0000;") != null);
    try std.testing.expect(std.mem.indexOf(u8, residual.pe_program, "base + 1 < @as(u32, chunk_size)") != null);
    try std.testing.expect(std.mem.indexOf(u8, residual.combined, "f32") == null);

    const tiled = try emitPatternSectionsForElem(std.testing.allocator, "tiled_matmul", .f16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, tiled.layout, "[*]f16") != null);
    try std.testing.expect(std.mem.indexOf(u8, tiled.pe_program, "[Mt * Kt]f16") != null);
    try std.testing.expect(std.mem.indexOf(u8, tiled.combined, "f32") == null);
    try std.testing.expect(std.mem.indexOf(u8, tiled.pe_program, "@fmacs(C_dsd") == null);
    try std.testing.expect(std.mem.indexOf(u8, tiled.pe_program, "C_tile[c_idx] += Ap.*[a_idx] * b_val") != null);

    const sample_sections = try emitPatternSectionsForElem(std.testing.allocator, "sample", .f16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, sample_sections.pe_program, "-65504.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, sample_sections.pe_program, "-3.4028235e+38") == null);
    try std.testing.expect(std.mem.indexOf(u8, sample_sections.pe_program, "var scratch_in") == null);
    try std.testing.expect(std.mem.indexOf(u8, sample_sections.pe_program, "@bitcast(u32, scratch_in[1])") == null);
    try std.testing.expect(std.mem.indexOf(u8, sample_sections.pe_program, "output_token[0] = local_max_idx;") != null);

    const gemv = try emitPatternSectionsForElem(std.testing.allocator, "fused_gemv_dequant", .f16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, gemv.layout, "param host_reduce: i16 = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.layout, ".host_reduce = host_reduce") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.layout, "@export_name(\"output\", [*]f16, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.layout, "@export_name(\"partial\", [*]f32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.layout, "@export_name(\"reduced\", [*]f32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "var partial: [out_dim_per_pe]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "var partial_ptr: [*]f32 = &partial;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "var reduced: [out_dim_per_pe]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "var reduced_ptr: [*]f32 = &reduced;") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "var weight_col: [out_dim_per_pe]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "var partial_dsd = @get_dsd(mem1d_dsd") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "@fmacs(partial_dsd, partial_dsd, weight_col_dsd") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "if (host_reduce != 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "@export_symbol(partial_ptr, \"partial\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "@export_symbol(reduced_ptr, \"reduced\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "mpi_x.reduce_fadds(@as(u16, num_pes - 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "mpi_x.gather(@as(u16, num_pes - 1)") == null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "var sum:") == null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "out_dim_per_pe * num_pes") == null);
    try std.testing.expect(std.mem.indexOf(u8, gemv.pe_program, "output[@as(u32, row)] = @as(f16, reduced[@as(u32, row)]);") != null);

    const dense = try emitPatternSectionsForElem(std.testing.allocator, "dense_gemv", .f16, &buf);
    try std.testing.expect(std.mem.indexOf(u8, dense.layout, ".pe_y = @as(i16, pe_y)") != null);
    try std.testing.expect(std.mem.indexOf(u8, dense.layout, "const c2d = @import_module(\"<collectives_2d/params>\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, dense.pe_program, "param pe_y: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, dense.pe_program, "param c2d_params;") != null);
    try std.testing.expect(std.mem.indexOf(u8, dense.pe_program, "fn unblock_completion_row() void") != null);
    try std.testing.expect(std.mem.indexOf(u8, dense.pe_program, "var partial: [out_dim_per_pe]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, dense.pe_program, "mpi_x.reduce_fadds(@as(u16, num_pes - 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, dense.pe_program, "@mov32(reduce_out, scratch_out_dsd") == null);
    try std.testing.expect(std.mem.indexOf(u8, dense.layout, "@set_color_config") == null);
}

test "host compile source emits fused FFN collectives row reduction" {
    var buf: [32768]u8 = undefined;

    const ffn = try emitPatternSections(std.testing.allocator, "fused_ffn", &buf);
    try std.testing.expect(std.mem.indexOf(u8, ffn.layout, "const c2d = @import_module(\"<collectives_2d/params>\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, ffn.layout, ".c2d_params = c2d_tile_params") != null);
    try std.testing.expect(std.mem.indexOf(u8, ffn.layout, "@set_color_config") == null);
    try std.testing.expect(std.mem.indexOf(u8, ffn.pe_program, "param c2d_params;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ffn.pe_program, "const mpi_x = @import_module(\"<collectives_2d/pe>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ffn.pe_program, "var gate_reduced: [out_dim]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, ffn.pe_program, "var up_reduced: [out_dim]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, ffn.pe_program, "mpi_x.reduce_fadds(@as(u16, num_pes - 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, ffn.pe_program, "@fmovs(reduce_out") == null);
    try std.testing.expect(std.mem.indexOf(u8, ffn.pe_program, "param reduce_color") == null);
}

test "host compile source emits tiled attention score cache" {
    var buf: [32768]u8 = undefined;

    const tiled = try emitPatternSections(std.testing.allocator, "attention_tiled", &buf);
    try std.testing.expect(std.mem.indexOf(u8, tiled.pe_program, "var score_cache: [block_size]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, tiled.pe_program, "score_cache[@as(u32, bi)] = score;") != null);
    try std.testing.expect(std.mem.indexOf(u8, tiled.pe_program, "const w = math.exp(score_cache[@as(u32, bi)] - m_new);") != null);
    try std.testing.expect(std.mem.indexOf(u8, tiled.pe_program, "const w = math.exp(score * scale - m_new);") == null);
}

test "host compile source emits semantic Gemma elementwise bodies" {
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;

    const rms = try emitPatternSections(std.testing.allocator, "rms_norm", &buf);
    try std.testing.expect(std.mem.indexOf(u8, rms.layout, "@export_name(\"weight\", [*]f32, true);") != null);
    // The TSIR-driven body uses `v` as the loop temporary and the
    // NR-refined `sqrt_nr` wrapper with the literal epsilon inline;
    // the load-bearing semantic invariants are: a sum-of-squares
    // accumulator, a sqrt-with-epsilon, the Gemma `1.0 + weight`
    // offset on the per-element output, and no toy-WGSL `partial`
    // workgroup accumulator leaking through.
    try std.testing.expect(std.mem.indexOf(u8, rms.pe_program, "sum_sq +=") != null);
    try std.testing.expect(std.mem.indexOf(u8, rms.pe_program, "fn sqrt_nr(x: f32) f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, rms.pe_program, "sqrt_nr(mean_sq + 0.000001)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rms.pe_program, "1.0 + weight[") != null);
    try std.testing.expect(std.mem.indexOf(u8, rms.pe_program, "partial") == null);

    const residual = try emitPatternSections(std.testing.allocator, "residual", &buf);
    try std.testing.expect(std.mem.indexOf(u8, residual.layout, "@export_name(\"input\", [*]f32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, residual.layout, "@export_name(\"residual\", [*]f32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, residual.pe_program, "+ residual[") != null);
    try std.testing.expect(std.mem.indexOf(u8, residual.pe_program, "* 1.0") == null);

    const gelu = try emitPatternSections(std.testing.allocator, "gelu", &buf);
    try std.testing.expect(std.mem.indexOf(u8, gelu.layout, "@export_name(\"input\", [*]f32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, gelu.pe_program, "math.tanh(t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gelu.pe_program, "0.5 * x") != null);
}

test "host compile source emits TSIR KV cache bodies" {
    // Slot-sharded residency strategy: each PE owns ceil(max_seq_len /
    // num_pes) slots of [head_dim]f32 instead of the full
    // [max_seq_len * head_dim]f32 cache. Layout-side `pe_id`,
    // `num_pes`, `slots_per_pe` are passed via @set_tile_code in
    // `emit_csl_layout.zig:emitKvWriteLayout`. The write body guards
    // on `owning_pe == pe_id` so only the owning PE mutates its local
    // slot; non-owning PEs no-op.
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;

    const kv_write = try emitPatternSections(std.testing.allocator, "kv_write", &buf);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "param max_seq_len: i16 = 4096;") != null);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "param pe_id: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "param num_pes: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "param slots_per_pe: i16") != null);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "const local_kv_len: u32 = @as(u32, slots_per_pe) * @as(u32, head_dim);") != null);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "if (owning_pe == @as(u32, pe_id))") != null);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "key_cache[idx] = key_proj[@as(u32, d)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "val_cache[idx] = val_proj[@as(u32, d)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "@export_symbol(position_ptr, \"position\");") != null);
    // Full-per-pe artifacts must NOT appear under the slot-sharded path.
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "[kv_cache_len]f32") == null);
    try std.testing.expect(std.mem.indexOf(u8, kv_write.pe_program, "gid.x") == null);

    const read = try emitPatternSections(std.testing.allocator, "kv_read", &buf);
    try std.testing.expect(std.mem.indexOf(u8, read.pe_program, "param pe_id: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.pe_program, "param num_pes: i16;") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.pe_program, "param slots_per_pe: i16") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.pe_program, "const local_kv_len: u32 = @as(u32, slots_per_pe) * @as(u32, head_dim);") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.pe_program, "[local_kv_len]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.pe_program, "@export_symbol(key_out_ptr, \"key_out\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, read.pe_program, "[kv_cache_len]f32") == null);
    try std.testing.expect(std.mem.indexOf(u8, read.pe_program, "gid.x") == null);
}

test "host compile source tiled matmul exports WGSL storage names" {
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;
    const sections = try emitPatternSections(std.testing.allocator, "tiled_matmul", &buf);

    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@export_name(\"a\", [*]f32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@export_name(\"b\", [*]f32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@export_name(\"c\", [*]f32, true);") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "@export_symbol(A_ptr, \"a\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "@export_symbol(B_ptr, \"b\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "@export_symbol(C_ptr, \"c\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "@export_symbol(A_ptr, \"A\");") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "@export_symbol(B_ptr, \"B\");") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "@export_symbol(C_ptr, \"C\");") == null);
}

test "host compile source gather uses layout coordinates" {
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;
    const sections = try emitPatternSections(std.testing.allocator, "gather", &buf);

    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const layout_mod = @import_module(\"<layout>\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "layout_mod.get_x_coord()") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "layout_mod.get_y_coord()") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".width = width,") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".height = height,") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".pe_x = pe_x") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".pe_y = pe_y") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".pe_id = pe_y * width + pe_x") == null);
}

test "host compile source elementwise uses layout coordinates" {
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;
    const sections = try emitPatternSections(std.testing.allocator, "element_wise", &buf);

    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const layout_mod = @import_module(\"<layout>\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "layout_mod.get_x_coord()") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "layout_mod.get_y_coord()") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".width = width,") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".height = height,") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".pe_id = pe_y * width + pe_x") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.layout, ".num_pes = width * height") == null);
}

test "host compile source rope avoids CSL builtin names" {
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;
    const sections = try emitPatternSections(std.testing.allocator, "rope", &buf);

    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const dim0 =") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const dim1 =") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const i0 =") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "const i1 =") == null);
}

test "host compile source decode attention leaves color routing in layout" {
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;
    const sections = try emitPatternSections(std.testing.allocator, "attention_decode", &buf);

    try std.testing.expect(std.mem.indexOf(u8, sections.layout, "@set_color_config") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "@set_local_color_config(reduce_color") == null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "[kv_chunk * head_dim]f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "[q_len * head_dim]f32") == null);
}

test "host compile source rejects unknown HostPlan pattern" {
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedPattern,
        emitPatternSections(std.testing.allocator, "not_a_pattern", &buf),
    );
}

test "reduction pattern emits real rmsnorm: chunked sum, sqrt, per-element output with weight" {
    // The toy REDUCTION_WGSL it replaced wrote one scalar per PE. The real
    // rmsnorm shape: chunked sum-of-squares pre-barrier, single workgroup
    // barrier, post-barrier per-element output with weight scaling and
    // optional Gemma `1+w` offset. Lock the lowering signal so any future
    // regression to a scalar-per-PE shape fails this test.
    var buf: [mod.MAX_CSL_OUTPUT]u8 = undefined;
    const sections = try emitPatternSections(std.testing.allocator, "reduction", &buf);

    // Inverse RMS computation must be present (NR-refined sqrt + division).
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "sqrt_nr") != null);

    // Weight binding must be threaded through to the per-element output.
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "weight") != null);

    // Per-element output loop bounded by the runtime size, not by workgroup_size 64.
    // A scalar-per-PE regression would write `output[...] = sum;` once and skip
    // the size-bounded loop.
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "i < @as(u32, hidden_size)") != null);

    // Gemma offset path must be reachable. Uniform structs lower to a single
    // u32 buffer, so rms_norm_offset is slot 2 of `u`.
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "u[2]") != null);

    // Single-barrier shape preserved (pre/post barrier zones).
    // The lane-loop wrap is the existing reduction emitter contract.
    try std.testing.expect(std.mem.indexOf(u8, sections.pe_program, "@range(u32, 64)") != null);
}
