// emit_csl_matmul_q4k.zig — CSL PE program for SUMMA tiled matmul with
// Q4_K_M-quantized B operand, dequantized on the PE.
//
// Companion to emit_csl_matmul.zig (the f32-only SUMMA emit). Mirrors the
// same SUMMA control flow on a P×P PE grid using collectives_2d for
// row/column broadcasts; the only behavioral delta is the B operand:
//
//   emit_csl_matmul.zig:    B_tile is `[Kt * Nt]f32`. Host pre-dequants Q4_K_M
//                           to f32 on CPU and pushes f32 over the memcpy
//                           fabric. ~7× more bytes than necessary.
//
//   emit_csl_matmul_q4k.zig: B_tile_q4k is `[Kt * Nt / 256]Q4KBlock` (144
//                           bytes per 256-weight block). Host pushes the
//                           raw Q4K bytes; PE materializes a working f32
//                           B_tile via a `dequant_b_tile()` prologue
//                           before the local GEMM step. Same fmacs
//                           inner loop as the f32 path.
//
// Q4_K_M block layout (canonical llama.cpp, 144 bytes per 256 weights):
//
//   bytes  0..1   d:    f16 super-block scale
//   bytes  2..3   dmin: f16 super-block min
//   bytes  4..15  scales/mins:  packed 6-bit scale and min for each of 8
//                                32-weight sub-blocks (12 bytes total)
//   bytes 16..143 qs:   packed 4-bit weights (128 bytes for 256 weights)
//
// Bit-packing of scales/mins matches both Doppler's WGSL
// `fused_matmul_q4_widetile.wgsl::get_scale_min_k4` and Doe's Python
// `bench/tools/doppler_rdrr_q4k.py::unpack_q4k_scale_min_bits`. The
// per-element dequant arithmetic is:
//
//   scale_sub = d    * scale_bits[sub]
//   min_sub   = dmin * min_bits[sub]
//   weight    = scale_sub * f32(quant_4bit) - min_sub
//
// SUMMA tile-size constraint preserved by Gemma 4 31B's compile sweep
// (Kt = 2560 = 10 × 256): block boundaries align with the K-axis tile
// dimension, so no Q4K block straddles tile boundaries and no
// cross-PE block reassembly is needed.

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const text_buffer = @import("csl_text_buffer.zig");

const write = text_buffer.write;

pub const EmitError = error{
    OutputTooLarge,
    InvalidIr,
    UnsupportedBuiltin,
    UnsupportedConstruct,
};

/// Per-256-weight-block byte count. Constant matches both the Doppler
/// WGSL kernel and Doe's existing Python decoder.
pub const Q4_K_M_BLOCK_BYTES: u32 = 144;

/// Per-super-block sub-block count and weights-per-sub-block. 8
/// sub-blocks × 32 weights = 256 weights per Q4K block.
pub const Q4_K_M_SUBBLOCKS: u32 = 8;
pub const Q4_K_M_SUBBLOCK_ELEMENTS: u32 = 32;
pub const Q4_K_M_BLOCK_ELEMENTS: u32 = Q4_K_M_SUBBLOCKS * Q4_K_M_SUBBLOCK_ELEMENTS;

/// Emit a CSL PE program implementing SUMMA matmul with Q4_K_M B input.
/// Host wires the standard Mt/Kt/Nt/P params plus the existing
/// c2d_params/memcpy_params; B_ptr is exported as a `[*]u8` over Q4K
/// bytes rather than the f32 path's `[*]f32`.
pub fn emit(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    entry: ir.EntryPoint,
    info: classify.MatmulInfo,
) EmitError!void {
    _ = entry;
    _ = info;

    const a_export = storageExportName(module, 0, "A");
    const b_export = storageExportName(module, 1, "B");
    const c_export = storageExportName(module, 2, "C");

    try write(buf, pos, "// PE program: SUMMA tiled matmul with Q4_K_M B (auto-generated from WGSL)\n");
    try write(buf, pos, "// P×P PE grid, collectives_2d for row/column broadcasts.\n");
    try write(buf, pos, "// C[M,N] = A[M,K] * dequantize(B_q4k)^T[N,K]\n");
    try write(buf, pos, "// Q4K block: 144 bytes per 256 weights (d/dmin f16, scales 12B, qs 128B).\n\n");

    // Params identical to f32 SUMMA path.
    try write(buf, pos, "param c2d_params;\n");
    try write(buf, pos, "param memcpy_params;\n");
    try write(buf, pos, "param Mt: i16;\n");
    try write(buf, pos, "param Kt: i16;\n");
    try write(buf, pos, "param Nt: i16;\n");
    try write(buf, pos, "param P: u16;\n\n");

    // Imports.
    try write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try write(buf, pos, "const mpi_x = @import_module(\"<collectives_2d/pe>\", .{\n");
    try write(buf, pos, "    .dim_params = c2d_params.x,\n");
    try write(buf, pos, "    .queues = [2]u16{2, 4},\n");
    try write(buf, pos, "    .dest_dsr_ids = [1]u16{1},\n");
    try write(buf, pos, "    .src0_dsr_ids = [1]u16{1},\n");
    try write(buf, pos, "    .src1_dsr_ids = [1]u16{1},\n");
    try write(buf, pos, "});\n");
    try write(buf, pos, "const mpi_y = @import_module(\"<collectives_2d/pe>\", .{\n");
    try write(buf, pos, "    .dim_params = c2d_params.y,\n");
    try write(buf, pos, "    .queues = [2]u16{3, 5},\n");
    try write(buf, pos, "    .dest_dsr_ids = [1]u16{2},\n");
    try write(buf, pos, "    .src0_dsr_ids = [1]u16{2},\n");
    try write(buf, pos, "    .src1_dsr_ids = [1]u16{2},\n");
    try write(buf, pos, "});\n\n");

    // Q4K block layout. CSL packed struct mirrors the canonical
    // llama.cpp layout: 4 + 12 + 128 = 144 bytes total.
    // Use i16 to match Kt/Nt's type — CSL rejects mixed signed/unsigned
    // arithmetic in array-dimension expressions (e.g.
    // `[(Kt * Nt / QK_K) * QK_K_BLOCK_BYTES]u8`).
    try write(buf, pos, "// Q4_K_M super-block: 256 weights packed into 144 bytes.\n");
    try write(buf, pos, "const QK_K: i16 = 256;\n");
    try write(buf, pos, "const QK_K_SUBBLOCKS: i16 = 8;\n");
    try write(buf, pos, "const QK_K_SUBBLOCK_ELEMENTS: i16 = 32;\n");
    try write(buf, pos, "const QK_K_BLOCK_BYTES: i16 = 144;\n");
    try write(buf, pos, "const QK_K_QUANT_BYTE_OFFSET: i16 = 16;\n\n");

    // Tile storage. A_tile and C_tile remain f32; B materializes from
    // Q4K bytes on broadcast.
    try write(buf, pos, "var A_tile = @zeros([Mt * Kt]f32);\n");
    try write(buf, pos, "var B_tile = @zeros([Kt * Nt]f32);\n");
    try write(buf, pos, "var C_tile = @zeros([Mt * Nt]f32);\n");
    try write(buf, pos, "var A_buf  = @zeros([Mt * Kt]f32);\n");
    try write(buf, pos, "// B_tile_q4k holds the broadcast-received Q4K bytes; one block per\n");
    try write(buf, pos, "// 256-weight stride along the (Kt × Nt) flattened tile.\n");
    try write(buf, pos, "var B_tile_q4k = @zeros([(Kt * Nt / QK_K) * QK_K_BLOCK_BYTES]u8);\n");
    try write(buf, pos, "var B_buf_q4k  = @zeros([(Kt * Nt / QK_K) * QK_K_BLOCK_BYTES]u8);\n\n");

    // Pointers for export. Note B_ptr is u8 (Q4K byte stream) rather
    // than f32; A and C remain f32.
    try write(buf, pos, "var A_ptr: [*]f32 = &A_tile;\n");
    try write(buf, pos, "var B_ptr: [*]u8  = &B_tile_q4k;\n");
    try write(buf, pos, "var C_ptr: [*]f32 = &C_tile;\n\n");

    // State.
    try write(buf, pos, "var step: u16 = 0;\n");
    try write(buf, pos, "var px: u16 = 0;\n");
    try write(buf, pos, "var py: u16 = 0;\n\n");

    // Task IDs (matches f32 path).
    try write(buf, pos, "const exit_task_id:    local_task_id = @get_local_task_id(12);\n");
    try write(buf, pos, "const compute_task_id: local_task_id = @get_local_task_id(13);\n");
    try write(buf, pos, "const x_done_id:       local_task_id = @get_local_task_id(14);\n");
    try write(buf, pos, "const y_done_id:       local_task_id = @get_local_task_id(15);\n\n");

    // Synchronization flags.
    try write(buf, pos, "var x_done: bool = false;\n");
    try write(buf, pos, "var y_done: bool = false;\n\n");

    // ---- Helpers: f16 unpack and Q4K bit-packing accessor ----

    try write(buf, pos, "// Unpack a packed u32 (lo half) as f16 → f32 using CSL's\n");
    try write(buf, pos, "// `@bitcast(@fp16(), u16)` reinterpretation followed by an\n");
    try write(buf, pos, "// implicit f16→f32 widen via `@as(f32, ...)`.\n");
    try write(buf, pos, "fn unpack_f16_lo(word: u32) f32 {\n");
    try write(buf, pos, "    const lo: u16 = @as(u16, word & 0xFFFF);\n");
    try write(buf, pos, "    const f: f16 = @bitcast(@fp16(), lo);\n");
    try write(buf, pos, "    return @as(f32, f);\n");
    try write(buf, pos, "}\n\n");

    try write(buf, pos, "// Read a single byte from a Q4K-byte buffer at logical block-and-byte offset.\n");
    try write(buf, pos, "fn q4k_byte_at(buf_ptr: [*]u8, block_idx: i16, byte_idx: i16) u8 {\n");
    try write(buf, pos, "    const off: u32 = @as(u32, block_idx) * @as(u32, QK_K_BLOCK_BYTES) + @as(u32, byte_idx);\n");
    try write(buf, pos, "    return buf_ptr[off];\n");
    try write(buf, pos, "}\n\n");

    try write(buf, pos, "// Decode the 6-bit scale and min for sub-block `sub` (0..7) of a Q4K\n");
    try write(buf, pos, "// super-block read from `buf_ptr`. Mirrors Doppler's WGSL\n");
    try write(buf, pos, "// get_scale_min_k4 and Doe's Python unpack_q4k_scale_min_bits.\n");
    try write(buf, pos, "// Returns sc and mn packed into a u16 (sc in low byte, mn in high\n");
    try write(buf, pos, "// byte) — CSL rejects array return types at runtime.\n");
    try write(buf, pos, "fn q4k_scale_min_bits(buf_ptr: [*]u8, block_idx: i16, sub: i16) u16 {\n");
    try write(buf, pos, "    var sc: u8 = 0;\n");
    try write(buf, pos, "    var mn: u8 = 0;\n");
    try write(buf, pos, "    if (sub < 4) {\n");
    try write(buf, pos, "        sc = q4k_byte_at(buf_ptr, block_idx, 4 + sub) & 0x3F;\n");
    try write(buf, pos, "        mn = q4k_byte_at(buf_ptr, block_idx, 8 + sub) & 0x3F;\n");
    try write(buf, pos, "    } else {\n");
    try write(buf, pos, "        const base: i16 = sub - 4;\n");
    try write(buf, pos, "        const mid:  u8  = q4k_byte_at(buf_ptr, block_idx, 12 + base);\n");
    try write(buf, pos, "        const lo_b: u8  = q4k_byte_at(buf_ptr, block_idx, 4  + base);\n");
    try write(buf, pos, "        const hi_b: u8  = q4k_byte_at(buf_ptr, block_idx, 8  + base);\n");
    try write(buf, pos, "        sc = (mid & 0x0F) | ((lo_b >> 6) << 4);\n");
    try write(buf, pos, "        mn = (mid >> 4)   | ((hi_b >> 6) << 4);\n");
    try write(buf, pos, "    }\n");
    try write(buf, pos, "    return @as(u16, sc) | (@as(u16, mn) << 8);\n");
    try write(buf, pos, "}\n\n");

    // ---- Q4K → f32 dequant of the local B tile ----
    //
    // This runs once after each broadcast step, materializing the
    // post-broadcast Q4K bytes (in `Bp_q4k`) into the f32 working
    // `B_tile`. The downstream fmacs loop reads `B_tile` exactly the
    // way the f32 path does.
    try write(buf, pos, "// Materialize the f32 B tile from the Q4K-byte tile staged by the\n");
    try write(buf, pos, "// broadcast. Per-block decode walks 4 chunks of 32 bytes each.\n");
    try write(buf, pos, "// For each byte at chunk*32+index, the LOW nibble lands at output\n");
    try write(buf, pos, "// position chunk*64+index (sub-block 2*chunk) and the HIGH nibble\n");
    try write(buf, pos, "// lands at chunk*64+32+index (sub-block 2*chunk+1). The two halves\n");
    try write(buf, pos, "// of one byte therefore use DIFFERENT scale/min — scales[2*chunk]\n");
    try write(buf, pos, "// for the lo half, scales[2*chunk+1] for the hi half. This matches\n");
    try write(buf, pos, "// `bench/tools/doppler_rdrr_q4k.py::dequantize_q4km_block` byte for\n");
    try write(buf, pos, "// byte and the canonical llama.cpp Q4_K_M dequant.\n");
    try write(buf, pos, "fn dequant_b_tile(buf_ptr: [*]u8) void {\n");
    try write(buf, pos, "    const blocks_per_tile: i16 = Kt * Nt / QK_K;\n");
    try write(buf, pos, "    for (@range(i16, blocks_per_tile)) |bi| {\n");
    try write(buf, pos, "        const lo_word: u32 =\n");
    try write(buf, pos, "            (@as(u32, q4k_byte_at(buf_ptr, bi, 0)))\n");
    try write(buf, pos, "          | (@as(u32, q4k_byte_at(buf_ptr, bi, 1)) << 8);\n");
    try write(buf, pos, "        const hi_word: u32 =\n");
    try write(buf, pos, "            (@as(u32, q4k_byte_at(buf_ptr, bi, 2)))\n");
    try write(buf, pos, "          | (@as(u32, q4k_byte_at(buf_ptr, bi, 3)) << 8);\n");
    try write(buf, pos, "        const d:    f32 = unpack_f16_lo(lo_word);\n");
    try write(buf, pos, "        const dmin: f32 = unpack_f16_lo(hi_word);\n");
    try write(buf, pos, "        for (@range(i16, 4)) |chunk| {\n");
    try write(buf, pos, "            const lo_sub: i16 = chunk * 2;\n");
    try write(buf, pos, "            const hi_sub: i16 = chunk * 2 + 1;\n");
    try write(buf, pos, "            const sm_lo: u16 = q4k_scale_min_bits(buf_ptr, bi, lo_sub);\n");
    try write(buf, pos, "            const sm_hi: u16 = q4k_scale_min_bits(buf_ptr, bi, hi_sub);\n");
    try write(buf, pos, "            const scale_lo: f32 = d    * @as(f32, @as(i16, sm_lo & 0xFF));\n");
    try write(buf, pos, "            const min_lo:   f32 = dmin * @as(f32, @as(i16, (sm_lo >> 8) & 0xFF));\n");
    try write(buf, pos, "            const scale_hi: f32 = d    * @as(f32, @as(i16, sm_hi & 0xFF));\n");
    try write(buf, pos, "            const min_hi:   f32 = dmin * @as(f32, @as(i16, (sm_hi >> 8) & 0xFF));\n");
    try write(buf, pos, "            const chunk_base:    u32 = @as(u32, chunk) * 64;\n");
    try write(buf, pos, "            const qs_byte_base: i16 = QK_K_QUANT_BYTE_OFFSET + chunk * 32;\n");
    try write(buf, pos, "            for (@range(i16, 32)) |idx| {\n");
    try write(buf, pos, "                const packed_byte: u8 = q4k_byte_at(buf_ptr, bi, qs_byte_base + idx);\n");
    try write(buf, pos, "                const lo_nib: i16 = @as(i16, packed_byte & 0x0F);\n");
    try write(buf, pos, "                const hi_nib: i16 = @as(i16, (packed_byte >> 4) & 0x0F);\n");
    try write(buf, pos, "                const out_lo: u32 = @as(u32, bi) * @as(u32, QK_K) + chunk_base + @as(u32, idx);\n");
    try write(buf, pos, "                const out_hi: u32 = out_lo + 32;\n");
    try write(buf, pos, "                B_tile[out_lo] = scale_lo * @as(f32, lo_nib) - min_lo;\n");
    try write(buf, pos, "                B_tile[out_hi] = scale_hi * @as(f32, hi_nib) - min_hi;\n");
    try write(buf, pos, "            }\n");
    try write(buf, pos, "        }\n");
    try write(buf, pos, "    }\n");
    try write(buf, pos, "}\n\n");

    // ---- Main entry — host-callable ----

    try write(buf, pos, "fn compute() void {\n");
    try write(buf, pos, "    if (step == 0) {\n");
    try write(buf, pos, "        mpi_x.init();\n");
    try write(buf, pos, "        mpi_y.init();\n");
    try write(buf, pos, "        px = mpi_x.pe_id;\n");
    try write(buf, pos, "        py = mpi_y.pe_id;\n");
    try write(buf, pos, "    }\n\n");

    // A path is unchanged from f32 SUMMA (A is f32). B path swaps to Q4K bytes.
    try write(buf, pos, "    const Ap = if (px == step) &A_tile else &A_buf;\n");
    try write(buf, pos, "    const Bp_q4k = if (py == step) &B_tile_q4k else &B_buf_q4k;\n\n");

    try write(buf, pos, "    x_done = false;\n");
    try write(buf, pos, "    y_done = false;\n\n");

    // Broadcast: A as f32 (same as f32 path), B as u32 words over Q4K bytes.
    // Q4K block is 144 bytes = 36 u32 words; total Q4K words per tile is
    // (Kt*Nt/QK_K) * 36.
    try write(buf, pos, "    mpi_x.broadcast(step, @ptrcast([*]u32, Ap), Mt * Kt, x_done_id);\n");
    try write(buf, pos, "    mpi_y.broadcast(step, @ptrcast([*]u32, Bp_q4k), (Kt * Nt / QK_K) * (QK_K_BLOCK_BYTES / 4), y_done_id);\n");
    try write(buf, pos, "}\n\n");

    // Broadcast done handlers.
    try write(buf, pos, "task x_done_task() void {\n");
    try write(buf, pos, "    x_done = true;\n");
    try write(buf, pos, "    if (y_done) @activate(compute_task_id);\n");
    try write(buf, pos, "}\n\n");

    try write(buf, pos, "task y_done_task() void {\n");
    try write(buf, pos, "    y_done = true;\n");
    try write(buf, pos, "    if (x_done) @activate(compute_task_id);\n");
    try write(buf, pos, "}\n\n");

    // Local GEMM step. Differs from f32 path only in that we run a
    // dequant prologue to materialize the f32 B tile before fmacs.
    try write(buf, pos, "task compute_step() void {\n");
    try write(buf, pos, "    const Ap = if (px == step) &A_tile else &A_buf;\n");
    try write(buf, pos, "    const Bp_q4k = if (py == step) &B_tile_q4k else &B_buf_q4k;\n\n");

    try write(buf, pos, "    // Q4K → f32 dequant of the post-broadcast B tile. After this\n");
    try write(buf, pos, "    // call, B_tile holds the same f32 weights the f32-path SUMMA\n");
    try write(buf, pos, "    // would receive directly from the host. The active Q4K buffer\n");
    try write(buf, pos, "    // is the one that just received the broadcast: B_tile_q4k for\n");
    try write(buf, pos, "    // the broadcaster (py == step), B_buf_q4k for receivers.\n");
    try write(buf, pos, "    dequant_b_tile(Bp_q4k);\n\n");

    // From here the fmacs loop is identical to the f32 path so the
    // numerical contract on output C is preserved: same A, same f32 B
    // values, same accumulation order.
    try write(buf, pos, "    var A_dsd = @get_dsd(mem1d_dsd, .{ .tensor_access = |i|{Mt} -> A_tile[i] });\n");
    try write(buf, pos, "    A_dsd = @set_dsd_base_addr(A_dsd, Ap);\n");
    try write(buf, pos, "    for (@range(i16, Kt)) |k| {\n");
    try write(buf, pos, "        var C_dsd = @get_dsd(mem1d_dsd, .{ .tensor_access = |i|{Mt} -> C_tile[i] });\n");
    try write(buf, pos, "        for (@range(i16, Nt)) |j| {\n");
    try write(buf, pos, "            const b_val = B_tile[@as(u32, j) * @as(u32, Kt) + @as(u32, k)];\n");
    try write(buf, pos, "            @fmacs(C_dsd, C_dsd, A_dsd, b_val);\n");
    try write(buf, pos, "            C_dsd = @increment_dsd_offset(C_dsd, Mt, f32);\n");
    try write(buf, pos, "        }\n");
    try write(buf, pos, "        A_dsd = @increment_dsd_offset(A_dsd, Mt, f32);\n");
    try write(buf, pos, "    }\n\n");

    try write(buf, pos, "    step += 1;\n");
    try write(buf, pos, "    if (step != P) {\n");
    try write(buf, pos, "        compute();\n");
    try write(buf, pos, "    } else {\n");
    try write(buf, pos, "        @activate(exit_task_id);\n");
    try write(buf, pos, "    }\n");
    try write(buf, pos, "}\n\n");

    // Exit.
    try write(buf, pos, "task exit_task() void {\n");
    try write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try write(buf, pos, "}\n\n");

    // Comptime bindings.
    try write(buf, pos, "comptime {\n");
    try write(buf, pos, "    @bind_local_task(x_done_task, x_done_id);\n");
    try write(buf, pos, "    @bind_local_task(y_done_task, y_done_id);\n");
    try write(buf, pos, "    @bind_local_task(compute_step, compute_task_id);\n");
    try write(buf, pos, "    @bind_local_task(exit_task, exit_task_id);\n\n");

    try write(buf, pos, "    @export_symbol(A_ptr, \"");
    try write(buf, pos, a_export);
    try write(buf, pos, "\");\n");
    try write(buf, pos, "    @export_symbol(B_ptr, \"");
    try write(buf, pos, b_export);
    try write(buf, pos, "\");\n");
    try write(buf, pos, "    @export_symbol(C_ptr, \"");
    try write(buf, pos, c_export);
    try write(buf, pos, "\");\n");
    try write(buf, pos, "    @export_symbol(compute);\n");
    try write(buf, pos, "}\n");
}

// ---------------------------------------------------------------------------
// Write helper (kept local to the module; mirrors emit_csl_matmul.zig
// rather than crossing a new module boundary at this point).
// ---------------------------------------------------------------------------

fn storageExportName(module: *const ir.Module, target_index: usize, fallback: []const u8) []const u8 {
    var index: usize = 0;
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        if (index == target_index) return global.name;
        index += 1;
    }
    return fallback;
}
