// emit_csl_gather.zig — CSL PE program for embedding gather.
//
// Maps Doppler's gather_f16.wgsl pattern to CSL on a 2-D PE grid:
//
//   * width × height shards the embedding table by row, using the PE's
//     layout coordinates to compute a flat row-shard id.
//   * hidden_per_pe chunks the hidden dimension across host launches. This
//     is required to fit Gemma-family embed table/output slices inside the
//     per-PE `.data.hi` budget (~63 KiB). The classifier/host picks
//     hidden_per_pe and tokens_per_chunk such that
//     `(rows_per_pe + tokens_per_chunk) * hidden_per_pe * 4 ≤ 48 KiB`.
//
// Token dispatch is chunked: host broadcasts one `tokens_per_chunk`-sized
// slice of `indices` at a time. Each PE writes the current hidden chunk into
// `[tokens_per_chunk, hidden_per_pe]f32`; host concatenates per token chunk
// and per hidden chunk to reassemble the full
// `[num_tokens, hidden_size]f32` output.
//
// Defaults preserve today's 1-D single-chunk behavior: with `height=1`,
// `hidden_per_pe=hidden_size`, and `tokens_per_chunk=num_tokens` the
// compute loop is identical to the pre-chunking emitter. Real shapes
// override via the layout params the host supplies; those overrides are what
// move the compile out of the i16-coercion + `.data.hi` overflow regime.
//
// Buffer names are resolved from the IR module, not hardcoded.
//
// First-chunk-only silent-drop hazard (see emit_csl_gather.zig history,
// 2026-04-24 TODO): until the host runner implements chunked dispatch
// across all tokens, calling this kernel with `tokens_per_chunk <
// num_tokens` without the matching `ceil(num_tokens / tokens_per_chunk)`
// launch sequence produces only the first chunk of output. The emitter
// cannot detect this from inside the PE program; the contract is that
// host orchestration owns chunk iteration.

const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const W = @import("emit_csl_ir_walk.zig");
const storage_emit = @import("csl_storage_emit.zig");

const emitBuf = storage_emit.emitBuffer;
const emitPtr = storage_emit.emitPointer;
const emitExport = storage_emit.emitExport;

pub const EmitError = W.EmitError;

pub fn emit(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.GatherInfo,
) EmitError!void {
    const idx = module.globals.items[info.indices_global].name;
    const tbl = module.globals.items[info.table_global].name;
    const out = module.globals.items[info.output_global].name;

    try W.write(buf, pos, "// PE program: embedding gather (auto-generated from WGSL)\n");
    try W.write(buf, pos, "// 2-D layout: width x height shards rows. Host orchestrates chunked\n");
    try W.write(buf, pos, "// dispatch across tokens and hidden slices (see emit_csl_gather.zig header).\n\n");

    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param width: u16;\n");
    try W.write(buf, pos, "param height: u16;\n");
    // Row sharding (unchanged): `rows_per_pe` rows held by each column PE.
    try W.write(buf, pos, "param rows_per_pe: i16;\n");
    // Hidden sharding: `hidden_per_pe` columns held by each PE for the
    // current host-driven hidden chunk.
    try W.write(buf, pos, "param hidden_size: i16;\n");
    try W.write(buf, pos, "param hidden_per_pe: i16;\n");
    // Chunked token dispatch (new): indices/output sized to one chunk;
    // host iterates ceil(num_tokens / tokens_per_chunk) launches.
    try W.write(buf, pos, "param num_tokens: i16;\n");
    try W.write(buf, pos, "param tokens_per_chunk: i16;\n\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try W.write(buf, pos, "const layout_mod = @import_module(\"<layout>\");\n\n");

    // Per-PE buffers:
    //   indices: one chunk of tokens (broadcast from host per-chunk)
    //   table:   this PE's (row shard × hidden shard) slice of the embedding table
    //   output:  this PE's hidden shard of the current chunk
    try emitBuf(buf, pos, idx, "[tokens_per_chunk]u32");
    try emitBuf(buf, pos, tbl, "[rows_per_pe * hidden_per_pe]f32");
    try emitBuf(buf, pos, out, "[tokens_per_chunk * hidden_per_pe]f32");
    try W.write(buf, pos, "\n");
    try emitPtr(buf, pos, idx, "u32");
    try emitPtr(buf, pos, tbl, "f32");
    try emitPtr(buf, pos, out, "f32");
    try W.write(buf, pos, "\n");

    // Compute: for each token in this chunk, check if the token's global
    // row is in this column-PE's row shard. If so, write this row's
    // hidden shard into the per-chunk output slice.
    try W.write(buf, pos, "fn compute() void {\n");
    try W.write(buf, pos, "    const pe_x = layout_mod.get_x_coord();\n");
    try W.write(buf, pos, "    const pe_y = layout_mod.get_y_coord();\n");
    try W.write(buf, pos, "    const flat_pe_id = @as(u32, pe_y) * @as(u32, width) + @as(u32, pe_x);\n");
    try W.write(buf, pos, "    const row_start = flat_pe_id * @as(u32, rows_per_pe);\n");
    try W.write(buf, pos, "    const row_end = row_start + @as(u32, rows_per_pe);\n\n");
    try W.write(buf, pos, "    for (@range(i16, tokens_per_chunk)) |t| {\n");
    try W.write(buf, pos, "        const token_id = ");
    try W.write(buf, pos, idx);
    try W.write(buf, pos, "[@as(u32, t)];\n");
    try W.write(buf, pos, "        if (token_id >= row_start and token_id < row_end) {\n");
    try W.write(buf, pos, "            const local_row = token_id - row_start;\n");
    try W.write(buf, pos, "            for (@range(i16, hidden_per_pe)) |d| {\n");
    try W.write(buf, pos, "                const src = local_row * @as(u32, hidden_per_pe) + @as(u32, d);\n");
    try W.write(buf, pos, "                const dst = @as(u32, t) * @as(u32, hidden_per_pe) + @as(u32, d);\n");
    try W.write(buf, pos, "                ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[dst] = ");
    try W.write(buf, pos, tbl);
    try W.write(buf, pos, "[src];\n");
    try W.write(buf, pos, "            }\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");

    try W.write(buf, pos, "comptime {\n");
    try emitExport(buf, pos, idx);
    try emitExport(buf, pos, tbl);
    try emitExport(buf, pos, out);
    try W.write(buf, pos, "    @export_symbol(compute);\n");
    try W.write(buf, pos, "}\n");
}
