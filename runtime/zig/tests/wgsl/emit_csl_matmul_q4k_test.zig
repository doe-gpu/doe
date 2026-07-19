// emit_csl_matmul_q4k_test.zig — Wedge 2 of fused-dequant SUMMA.
//
// Pins the CSL string contract emitted by
// `src/compiler/wgsl/emit/csl/emit_csl_matmul_q4k.zig`. The new emit is callable as a
// standalone function but is NOT yet wired to the WGSL classifier
// (KernelPattern dispatch is Wedge 3+). To test it directly we
// synthesize a minimal `ir.Module` with the three storage globals the
// emitter consumes for A/B/C export names and invoke `emit()`.
//
// What this test locks in:
//
//   - SUMMA control flow markers shared with the f32 path (the proof
//     that we kept the apples-to-apples SUMMA shape, not a different
//     algorithm).
//   - Q4K block-layout constants (128/144/256/8/32/16) match Doppler
//     WGSL `fused_matmul_q4_widetile.wgsl` and Doe Python
//     `bench/tools/doppler_rdrr_q4k.py`. A drift here means dequant
//     would silently desync from the Doppler reference path.
//   - B operand storage as `[*]u8` (Q4K bytes) instead of `[*]f32`.
//     This is the whole point of the wedge: smaller fabric memcpy.
//   - mpi_y broadcast size in u32 words = (Kt*Nt/QK_K)*(QK_K_BLOCK_BYTES/4)
//     — the ~7× reduction vs the f32 path's `Kt * Nt`.
//   - The `dequant_b_tile()` prologue is called inside `compute_step`
//     before the existing fmacs K-loop runs.
//   - The fmacs K-loop body matches the f32 path symbol-for-symbol so
//     numerical behaviour on C is preserved.

const std = @import("std");
const ir = @import("../../src/compiler/wgsl/ir/ir.zig");
const mod = @import("../../src/compiler/wgsl/mod.zig");
const matmul_q4k = @import("../../src/compiler/wgsl/emit/csl/emit_csl_matmul_q4k.zig");
const classify = @import("../../src/compiler/wgsl/emit/csl/emit_csl_classify.zig");

const allocator = std.testing.allocator;

fn appendStorageGlobal(
    module: *ir.Module,
    name: []const u8,
    ty: ir.TypeId,
    binding: u32,
) !void {
    try module.globals.append(module.allocator, .{
        .name = try ir.dup_string(module.allocator, name),
        .ty = ty,
        .class = .var_,
        .addr_space = .storage,
        .access = .read_write,
        .binding = .{ .group = 0, .binding = binding },
    });
}

fn buildMinimalModuleWithThreeStorageGlobals(module: *ir.Module) !void {
    const f32_ty = try module.types.intern(.{ .scalar = .f32 });
    try appendStorageGlobal(module, "input_a", f32_ty, 0);
    try appendStorageGlobal(module, "input_b", f32_ty, 1);
    try appendStorageGlobal(module, "output_c", f32_ty, 2);
}

fn emitToBuf(module: *const ir.Module, buf: []u8) !usize {
    var pos: usize = 0;
    const stub_entry: ir.EntryPoint = .{
        .function = 0,
        .stage = .compute,
        .workgroup_size = .{ 1, 1, 1 },
    };
    const stub_info: classify.MatmulInfo = .{
        .tile_a_global = 0,
        .tile_b_global = 1,
        .tile_m = 16,
        .tile_n = 16,
        .tile_k = 256,
    };
    try matmul_q4k.emit(buf, &pos, module, stub_entry, stub_info);
    return pos;
}

fn assertContains(csl: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, csl, needle) == null) {
        std.debug.print(
            "expected CSL fragment not found: `{s}`\n--- emitted ---\n{s}\n",
            .{ needle, csl },
        );
        return error.MissingFragment;
    }
}

fn assertNotContains(csl: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, csl, needle) != null) {
        std.debug.print(
            "forbidden CSL fragment present: `{s}`\n--- emitted ---\n{s}\n",
            .{ needle, csl },
        );
        return error.ForbiddenFragment;
    }
}

test "emit_csl_matmul_q4k: SUMMA control-flow markers preserved" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    try buildMinimalModuleWithThreeStorageGlobals(&module);

    var buf: [64 * 1024]u8 = undefined;
    const written = try emitToBuf(&module, &buf);
    const csl = buf[0..written];

    // The SUMMA shape on the f32 path uses these collective and task
    // primitives. We must keep the same shape on the Q4K variant so
    // host wiring stays apples-to-apples.
    const must_have_summa = [_][]const u8{
        "param c2d_params;",
        "param memcpy_params;",
        "param Mt: i16;",
        "param Kt: i16;",
        "param Nt: i16;",
        "param P: u16;",
        "@import_module(\"<memcpy/memcpy>\", memcpy_params)",
        "@import_module(\"<collectives_2d/pe>\"",
        "mpi_x.init();",
        "mpi_y.init();",
        "mpi_x.broadcast(",
        "mpi_y.broadcast(",
        "@bind_local_task(x_done_task, x_done_id);",
        "@bind_local_task(y_done_task, y_done_id);",
        "@bind_local_task(compute_step, compute_task_id);",
        "@bind_local_task(exit_task, exit_task_id);",
        "@export_symbol(compute);",
    };
    for (must_have_summa) |needle| try assertContains(csl, needle);
}

test "emit_csl_matmul_q4k: Q4K block-layout constants match Doppler/Doe canon" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    try buildMinimalModuleWithThreeStorageGlobals(&module);

    var buf: [64 * 1024]u8 = undefined;
    const written = try emitToBuf(&module, &buf);
    const csl = buf[0..written];

    // 256 weights, 8 sub-blocks of 32, 144 bytes total, qs starts at
    // byte 16. Drift here would silently desync from
    // bench/tools/doppler_rdrr_q4k.py and
    // doppler/src/gpu/kernels/fused_matmul_q4_widetile.wgsl.
    try assertContains(csl, "const QK_K: i16 = 256;");
    try assertContains(csl, "const QK_K_SUBBLOCKS: i16 = 8;");
    try assertContains(csl, "const QK_K_SUBBLOCK_ELEMENTS: i16 = 32;");
    try assertContains(csl, "const QK_K_BLOCK_BYTES: i16 = 144;");
    try assertContains(csl, "const QK_K_QUANT_BYTE_OFFSET: i16 = 16;");
}

test "emit_csl_matmul_q4k: B operand exports as u8 byte stream, not f32" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    try buildMinimalModuleWithThreeStorageGlobals(&module);

    var buf: [64 * 1024]u8 = undefined;
    const written = try emitToBuf(&module, &buf);
    const csl = buf[0..written];

    // The wedge: B is shipped as Q4K bytes, materialized to f32 on the
    // PE. A and C remain f32. If anyone reverts B back to f32 export,
    // the host plan no longer benefits from smaller fabric memcpy and
    // the wedge has been silently undone.
    try assertContains(csl, "var A_ptr: [*]f32 = &A_tile;");
    try assertContains(csl, "var B_ptr: [*]u8  = &B_tile_q4k;");
    try assertContains(csl, "var C_ptr: [*]f32 = &C_tile;");
    try assertNotContains(csl, "var B_ptr: [*]f32");
    try assertContains(csl, "var B_tile_q4k = @zeros([(Kt * Nt / QK_K) * QK_K_BLOCK_BYTES]u8);");
}

test "emit_csl_matmul_q4k: mpi_y broadcast carries Q4K bytes (not f32 weights)" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    try buildMinimalModuleWithThreeStorageGlobals(&module);

    var buf: [64 * 1024]u8 = undefined;
    const written = try emitToBuf(&module, &buf);
    const csl = buf[0..written];

    // The size argument to mpi_y.broadcast is the wedge's apples-to-apples
    // claim: ~7× smaller than the f32 path (which broadcasts Kt*Nt f32
    // words). We pin the exact expression so a refactor that drops the
    // /QK_K or /4 trips this test.
    try assertContains(
        csl,
        "mpi_y.broadcast(step, @ptrcast([*]u32, Bp_q4k), (Kt * Nt / QK_K) * (QK_K_BLOCK_BYTES / 4), y_done_id);",
    );
    // A path is unchanged: still Mt*Kt f32 words.
    try assertContains(
        csl,
        "mpi_x.broadcast(step, @ptrcast([*]u32, Ap), Mt * Kt, x_done_id);",
    );
}

test "emit_csl_matmul_q4k: dequant prologue runs before fmacs K-loop" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    try buildMinimalModuleWithThreeStorageGlobals(&module);

    var buf: [64 * 1024]u8 = undefined;
    const written = try emitToBuf(&module, &buf);
    const csl = buf[0..written];

    // The prologue function exists with the expected per-block structure.
    try assertContains(csl, "fn dequant_b_tile(buf_ptr: [*]u8) void {");
    try assertContains(csl, "fn unpack_f16_lo(word: u32) f32 {");
    try assertContains(csl, "fn q4k_byte_at(buf_ptr: [*]u8, block_idx: i16, byte_idx: i16) u8 {");
    try assertContains(csl, "fn q4k_scale_min_bits(buf_ptr: [*]u8, block_idx: i16, sub: i16) u16 {");

    // Prologue is invoked from compute_step *before* the @fmacs loop.
    // Locate the substring positions and assert ordering.
    const compute_step_at = std.mem.indexOf(u8, csl, "task compute_step()") orelse {
        std.debug.print("compute_step task missing\n--- emitted ---\n{s}\n", .{csl});
        return error.MissingComputeStep;
    };
    const dequant_call_at = std.mem.indexOfPos(u8, csl, compute_step_at, "dequant_b_tile(Bp_q4k);") orelse {
        std.debug.print("dequant_b_tile() call missing inside compute_step\n--- emitted ---\n{s}\n", .{csl});
        return error.MissingDequantCall;
    };
    const fmacs_at = std.mem.indexOfPos(u8, csl, dequant_call_at, "@fmacs(C_dsd, C_dsd, A_dsd, b_val);") orelse {
        std.debug.print("@fmacs not found after dequant_b_tile()\n--- emitted ---\n{s}\n", .{csl});
        return error.MissingFmacs;
    };
    if (!(compute_step_at < dequant_call_at and dequant_call_at < fmacs_at)) {
        std.debug.print(
            "ordering invariant broken: compute_step={d} dequant_call={d} fmacs={d}\n",
            .{ compute_step_at, dequant_call_at, fmacs_at },
        );
        return error.OrderingInvariantBroken;
    }
}

test "emit_csl_matmul_q4k: fmacs inner loop matches f32 SUMMA path" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    try buildMinimalModuleWithThreeStorageGlobals(&module);

    var buf: [64 * 1024]u8 = undefined;
    const written = try emitToBuf(&module, &buf);
    const csl = buf[0..written];

    // Numerical contract on C: same A/B values, same accumulation
    // order. Pin the exact loop body. If anyone reorders the K-loop or
    // changes the @increment_dsd_offset stride, this fires.
    try assertContains(csl, "for (@range(i16, Kt)) |k| {");
    try assertContains(csl, "for (@range(i16, Nt)) |j| {");
    try assertContains(csl, "const b_val = B_tile[@as(u32, j) * @as(u32, Kt) + @as(u32, k)];");
    try assertContains(csl, "@fmacs(C_dsd, C_dsd, A_dsd, b_val);");
    try assertContains(csl, "C_dsd = @increment_dsd_offset(C_dsd, Mt, f32);");
    try assertContains(csl, "A_dsd = @increment_dsd_offset(A_dsd, Mt, f32);");
}

// Synthetic WGSL: tiled matmul with Q4K-quantized B input. The shape
// the classifier looks for in Wedge 4:
//
//   - struct-typed storage buffer (Q4KBlock array) for the B operand
//   - 2 workgroup arrays (A tile + dequanted B tile)
//   - workgroupBarrier
//   - at least one loop (the K-tile loop in shared-memory tiled GEMM)
//
// This is the WGSL the Doppler-side q4 widetile kernel
// (`fused_matmul_q4_widetile.wgsl`) uses, simplified to the smallest
// shape the classifier needs to recognize.
const Q4K_TILED_MATMUL_WGSL =
    "struct Q4KBlock {\n" ++
    "    d_dmin: u32,\n" ++
    "    scales: array<u32, 3>,\n" ++
    "    qs: array<u32, 32>,\n" ++
    "}\n" ++
    "\n" ++
    "@group(0) @binding(0) var<storage, read> a: array<f32>;\n" ++
    "@group(0) @binding(1) var<storage, read> b_q4k: array<Q4KBlock>;\n" ++
    "@group(0) @binding(2) var<storage, read_write> c: array<f32>;\n" ++
    "\n" ++
    "var<workgroup> a_tile: array<f32, 256>;\n" ++
    "var<workgroup> b_tile: array<f32, 256>;\n" ++
    "\n" ++
    "@compute @workgroup_size(16, 16)\n" ++
    "fn main(\n" ++
    "    @builtin(local_invocation_id) lid: vec3u,\n" ++
    "    @builtin(global_invocation_id) gid: vec3u,\n" ++
    "    @builtin(workgroup_id) wid: vec3u,\n" ++
    ") {\n" ++
    "    var acc: f32 = 0.0;\n" ++
    "    let tile_count: u32 = 4u;\n" ++
    "    for (var t: u32 = 0u; t < tile_count; t = t + 1u) {\n" ++
    "        let block_idx = t * 16u + lid.y;\n" ++
    "        let block = b_q4k[block_idx];\n" ++
    "        let lo: u32 = block.d_dmin & 0xFFFFu;\n" ++
    "        let dq = f32(block.qs[lid.x] & 0xFu) * f32(lo);\n" ++
    "        a_tile[lid.y * 16u + lid.x] = a[gid.y * 64u + t * 16u + lid.x];\n" ++
    "        b_tile[lid.y * 16u + lid.x] = dq;\n" ++
    "        workgroupBarrier();\n" ++
    "        for (var k: u32 = 0u; k < 16u; k = k + 1u) {\n" ++
    "            acc = acc + a_tile[lid.y * 16u + k] * b_tile[k * 16u + lid.x];\n" ++
    "        }\n" ++
    "        workgroupBarrier();\n" ++
    "    }\n" ++
    "    c[gid.y * 64u + gid.x] = acc;\n" ++
    "}\n";

fn classifyWgsl(src: []const u8) !classify.KernelPattern {
    var module = try mod.analyzeToIr(allocator, src);
    defer module.deinit();
    std.debug.assert(module.entry_points.items.len >= 1);
    return classify.classify(&module, module.entry_points.items[0]);
}

test "emit_csl_matmul_q4k: classifier routes Q4K tiled matmul to the new variant" {
    const pattern = try classifyWgsl(Q4K_TILED_MATMUL_WGSL);
    switch (pattern) {
        .tiled_matmul_q4k_dequant_b => |info| {
            // tile_m/tile_n must be positive (workgroup_size 16×16 = 256
            // shared-memory tile elements). tile_k is the inner K-loop
            // length recovered by extractMatmulInfo.
            try std.testing.expect(info.tile_m > 0);
            try std.testing.expect(info.tile_n > 0);
        },
        .fused_gemv_dequant => {
            std.debug.print(
                "Q4K tiled matmul misclassified as fused_gemv_dequant (Wedge 4 regression)\n",
                .{},
            );
            return error.MisclassifiedAsFusedGemv;
        },
        .tiled_matmul => {
            std.debug.print(
                "Q4K tiled matmul misclassified as plain tiled_matmul (would lose Q4K dequant fusion)\n",
                .{},
            );
            return error.MisclassifiedAsPlainTiledMatmul;
        },
        else => |actual| {
            std.debug.print(
                "Q4K tiled matmul classified as unexpected pattern: {s}\n",
                .{@tagName(actual)},
            );
            return error.UnexpectedClassification;
        },
    }
}

test "emit_csl_matmul_q4k: end-to-end translateToCsl emits layout with B as [*]u8" {
    var buf: [128 * 1024]u8 = undefined;
    const written = try mod.translateToCsl(allocator, Q4K_TILED_MATMUL_WGSL, &buf);
    const csl = buf[0..written];

    // Layout section must export the B binding (binding 1) as a Q4K
    // byte stream, not f32. Wedge 5 contract.
    try assertContains(csl, "@export_name(\"b_q4k\", [*]u8, true);");
    try assertContains(csl, "@export_name(\"a\", [*]f32, true);");
    try assertContains(csl, "@export_name(\"c\", [*]f32, true);");
    try assertContains(csl, "Layout: SUMMA tiled matmul on a P x P PE grid (Q4K B operand).");

    // PE program section must carry the dequant prologue and the Q4K
    // block constants — proves the dispatch reaches the new emitter.
    try assertContains(csl, "fn dequant_b_tile(buf_ptr: [*]u8) void {");
    try assertContains(csl, "const QK_K_BLOCK_BYTES: i16 = 144;");
    try assertContains(csl, "var B_ptr: [*]u8  = &B_tile_q4k;");
    try assertNotContains(csl, "var B_ptr: [*]f32");
}

test "emit_csl_matmul_q4k: KernelPattern variant satisfies contract validity" {
    // Wedge 3: variant registered with the classifier contract. Until
    // Wedge 4 wires the classifier, no real WGSL produces this variant
    // — but the contract validity check must accept correctly-shaped
    // MatmulInfo (tile_k % 256 == 0 for Q4K block alignment) and
    // reject malformed shapes.
    const ok: classify.KernelPattern = .{
        .tiled_matmul_q4k_dequant_b = .{
            .tile_a_global = 0,
            .tile_b_global = 1,
            .tile_m = 16,
            .tile_n = 16,
            .tile_k = 2560, // Gemma 4 31B Kt = 10 × 256
        },
    };
    try std.testing.expect(classify.patternContractValid(ok));

    // Note: tile_k % 256 == 0 is enforced by the host plan at SUMMA
    // dispatch time (Wedge 6), not by the classifier contract. The
    // classifier's tile_k reflects the WGSL workgroup-loop shape
    // (default 16 from extractMatmulInfo), not the SUMMA Kt.

    const bad_zero: classify.KernelPattern = .{ .tiled_matmul_q4k_dequant_b = .{
        .tile_a_global = 0,
        .tile_b_global = 1,
        .tile_m = 0,
        .tile_n = 16,
        .tile_k = 256,
    } };
    try std.testing.expect(!classify.patternContractValid(bad_zero));
}

test "emit_csl_matmul_q4k: storage export names threaded from module globals" {
    var module = ir.Module.init(allocator);
    defer module.deinit();
    const f32_ty = try module.types.intern(.{ .scalar = .f32 });
    try appendStorageGlobal(&module, "qwen_attn_a", f32_ty, 0);
    try appendStorageGlobal(&module, "qwen_attn_b_q4k", f32_ty, 1);
    try appendStorageGlobal(&module, "qwen_attn_c", f32_ty, 2);

    var buf: [64 * 1024]u8 = undefined;
    const written = try emitToBuf(&module, &buf);
    const csl = buf[0..written];

    // The emit must use module-supplied storage names for export
    // symbols so host plan code can bind by name.
    try assertContains(csl, "@export_symbol(A_ptr, \"qwen_attn_a\");");
    try assertContains(csl, "@export_symbol(B_ptr, \"qwen_attn_b_q4k\");");
    try assertContains(csl, "@export_symbol(C_ptr, \"qwen_attn_c\");");
}
