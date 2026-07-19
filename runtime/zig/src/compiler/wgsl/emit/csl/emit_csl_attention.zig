// emit_csl_attention.zig — CSL PE program emitters for attention kernels.
//
// Three attention patterns mapped from Doppler's WGSL kernels:
//
//   streaming   — Per-PE sequential attention, no fabric (Qwen linear_attention)
//                 Each PE handles one (query_pos, head) pair.
//
//   decode      — Chunked KV with fabric reduction for online softmax
//                 KV distributed across PE row, fabric allreduce for max/sum.
//
//   tiled       — Flash Attention with K/V tile broadcasts for prefill
//                 P×P grid, tiles broadcast via collectives_2d.
//
// Buffer names are resolved from the IR module via the info struct.
//
// Manifest-scale blocker for `attn_head256` / `attn_head512` at Gemma 4 E2B
// (verified from bench/out/doppler-reference/gemma-4-e2b-int4ple-doe-csl-
// hostplan/compile/driver-logs/attn_head256.cslc.stderr.log):
// linker error `ran out of PE memory for data (section .bss)` with .bss
// spanning 147 KiB (head_dim=256) / 294 KiB (head_dim=512), vs ~63 KiB PE
// budget. Root cause: full KV-cache is PE-resident at manifest kv_len.
//
// Per-PE footprint (attn_head256, kv_len≈128):
//   query  q_len=32 * head_dim=256 * 4 =  32 KiB
//   key    kv_len    * head_dim    * 4 = 128 KiB
//   val    kv_len    * head_dim    * 4 = 128 KiB
//   K_tile block=32  * head_dim    * 4 =  32 KiB
//   V_tile block=32  * head_dim    * 4 =  32 KiB
//   output q_len=32  * head_dim    * 4 =  32 KiB
// attn_head512 doubles head_dim → all bytes 2× → 294 KiB .bss.
//
// Fix requires KV streaming: host streams K/V one `block_size`-rows tile
// at a time into the already-allocated K_tile/V_tile buffers; the full
// `key`/`val` PE-resident arrays are removed. Each host-side iteration
// sends one tile and launches the attention compute step which consumes
// the tile and updates online-softmax state.
//
// Touch points (~1-2 weeks):
//   - this file (emitTiled): drop `var key: [kv_len*head_dim]f32` and
//     `var val: [kv_len*head_dim]f32`; keep only `K_tile`/`V_tile` +
//     `kv_block_idx` counter + a `task_handler` per launched block.
//   - emit_csl_layout.zig `emitTiledAttentionLayout`: add `tile_rows: i16`
//     param; remove `kv_len` from per-tile params.
//   - streaming executor: emit a host-side loop that H2Ds K_tile/V_tile
//     per block then launches compute_tile.
//   - operation-graph schema: add `attention.kvStreaming.tileRows` /
//     `attention.kvStreaming.tileCount`.
//
// Do NOT drop the key/val arrays without wiring the host streaming loop —
// the compute loop silently reads uninitialized data and produces NaNs.

const std = @import("std");
const ir = @import("../../ir/ir.zig");
const classify = @import("emit_csl_classify.zig");
const spec = @import("csl_spec.zig");
const W = @import("emit_csl_ir_walk.zig");

pub const EmitError = W.EmitError;

// ---------------------------------------------------------------------------
// Streaming attention — per-PE, no fabric
// ---------------------------------------------------------------------------

pub fn emitStreaming(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.AttentionStreamingInfo,
) EmitError!void {
    const q = module.globals.items[info.q_global].name;
    const k = module.globals.items[info.k_global].name;
    const v = module.globals.items[info.v_global].name;
    const out = module.globals.items[info.output_global].name;

    try W.write(buf, pos, "// PE program: streaming attention (auto-generated from WGSL)\n");
    try W.write(buf, pos, "// Per-PE online softmax: each PE handles one (query, head) pair.\n");
    try W.write(buf, pos, "// No inter-PE communication — fully local.\n\n");

    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param pe_id: i16;\n");
    try W.write(buf, pos, "param num_pes: i16;\n\n");
    try W.write(buf, pos, "param head_dim: i16;\n");
    try W.write(buf, pos, "param q_len: i16 = 1;\n");
    try W.write(buf, pos, "param kv_len: i16;\n");
    try W.write(buf, pos, "param softcap: f32 = 0.0;\n");
    try W.write(buf, pos, "param scale: f32 = 0.125;\n\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try W.write(buf, pos, "const math = @import_module(\"<math>\");\n\n");

    try emitStoragePtrs(buf, pos, module);

    // Single-pass online softmax: track running max `m` and sum `l`,
    // rescale the accumulated output when a new max appears. Eliminates
    // the redundant second QK dot product of the prior 2-pass form.
    // Matches emitDecode::emitScoreLoop's online-softmax shape, extended
    // to also accumulate output here since streaming has no fabric stage.
    try W.write(buf, pos, "fn compute() void {\n");
    try W.write(buf, pos, "    var m: f32 = -3.4028235e+38;\n");
    try W.write(buf, pos, "    var l: f32 = 0.0;\n");
    try W.write(buf, pos, "    for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "        ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, d)] = 0.0;\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "    for (@range(i16, kv_len)) |kv_i| {\n");
    try W.write(buf, pos, "        var score: f32 = 0.0;\n");
    try W.write(buf, pos, "        for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "            const qi = ");
    try W.write(buf, pos, q);
    try W.write(buf, pos, "[@as(u32, d)];\n");
    try W.write(buf, pos, "            const ki = ");
    try W.write(buf, pos, k);
    try W.write(buf, pos, "[@as(u32, kv_i) * @as(u32, head_dim) + @as(u32, d)];\n");
    try W.write(buf, pos, "            score += qi * ki;\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        score *= scale;\n");
    try W.write(buf, pos, "        if (softcap != 0.0) {\n");
    try W.write(buf, pos, "            score = softcap * math.tanh(score / softcap);\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        if (score > m) {\n");
    try W.write(buf, pos, "            const rescale = math.exp(m - score);\n");
    try W.write(buf, pos, "            l *= rescale;\n");
    try W.write(buf, pos, "            for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "                ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, d)] *= rescale;\n");
    try W.write(buf, pos, "            }\n");
    try W.write(buf, pos, "            m = score;\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        const w = math.exp(score - m);\n");
    try W.write(buf, pos, "        l += w;\n");
    try W.write(buf, pos, "        for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "            const idx = @as(u32, d);\n");
    try W.write(buf, pos, "            ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[idx] += w * ");
    try W.write(buf, pos, v);
    try W.write(buf, pos, "[@as(u32, kv_i) * @as(u32, head_dim) + idx];\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "    }\n\n");

    // Normalize
    try W.write(buf, pos, "    const inv = 1.0 / l;\n");
    try W.write(buf, pos, "    for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "        ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, d)] *= inv;\n");
    try W.write(buf, pos, "    }\n\n");
    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");

    try emitComptime(buf, pos, module);
}

// ---------------------------------------------------------------------------
// Decode attention — chunked KV, fabric reduction
// ---------------------------------------------------------------------------

pub fn emitDecode(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.AttentionDecodeInfo,
) EmitError!void {
    const q = module.globals.items[info.q_global].name;
    const k = module.globals.items[info.k_global].name;
    const v = module.globals.items[info.v_global].name;
    const out = module.globals.items[info.output_global].name;

    try W.write(buf, pos, "// PE program: decode attention (auto-generated from WGSL)\n");
    try W.write(buf, pos, "// KV distributed across PE row, fabric allreduce for softmax.\n\n");

    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param pe_id: i16;\n");
    try W.write(buf, pos, "param num_pes: i16;\n");
    try W.write(buf, pos, "param reduce_color: color;\n\n");
    try W.write(buf, pos, "param head_dim: i16;\n");
    try W.write(buf, pos, "param kv_chunk: i16;\n");
    try W.write(buf, pos, "param scale: f32 = 0.125;\n");
    try W.write(buf, pos, "\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try W.write(buf, pos, "const math = @import_module(\"<math>\");\n\n");

    try emitDecodeStoragePtrs(buf, pos, module);
    try emitDecodeRuntimeState(buf, pos);

    // Local accumulators
    try W.write(buf, pos, "var local_max: f32 = -3.4028235e+38;\n");
    try W.write(buf, pos, "var local_sum: f32 = 0.0;\n");
    try W.write(buf, pos, "var global_max: f32 = -3.4028235e+38;\n");
    try W.write(buf, pos, "var global_sum: f32 = 0.0;\n\n");

    // wse3 DSD-to-DSD async fabric pattern (matches emit_csl_sample.zig
    // and emit_csl_fused.zig). The earlier emit used the wse2-era
    // synchronous `@fmovs(f32_var, fabin_dsd)` form in `task
    // reduce_recv` without an `.activate = reduce_task_id` annotation
    // anywhere, so the task was bound but never fired — every
    // simfabric launch hung at memcpy_d2h with `received length (0
    // bytes) is not expected`. Switching to scratch-buffer mem1d_dsds
    // and the async @mov32 form lets compute() arm the recv with
    // `.activate = reduce_task_id`, mirroring the canonical pattern.
    try W.write(buf, pos, "var scratch_in: [1]f32 = @zeros([1]f32);\n");
    try W.write(buf, pos, "var scratch_out: [1]f32 = @zeros([1]f32);\n");
    try W.write(buf, pos, "const scratch_in_dsd = @get_dsd(mem1d_dsd, .{ .tensor_access = |i|{1} -> scratch_in[i] });\n");
    try W.write(buf, pos, "const scratch_out_dsd = @get_dsd(mem1d_dsd, .{ .tensor_access = |i|{1} -> scratch_out[i] });\n");
    try W.write(buf, pos, "const reduce_out_q = @get_output_queue(2);\n");
    try W.write(buf, pos, "const reduce_in_q = @get_input_queue(2);\n");
    try W.write(buf, pos, "const reduce_out = @get_dsd(fabout_dsd, .{ .extent = 1, .output_queue = reduce_out_q });\n");
    try W.write(buf, pos, "const reduce_in = @get_dsd(fabin_dsd, .{ .extent = 1, .input_queue = reduce_in_q });\n\n");
    try W.write(buf, pos, "const reduce_task_id: local_task_id = @get_local_task_id(10);\n");
    try W.write(buf, pos, "const norm_task_id: local_task_id = @get_local_task_id(11);\n\n");

    // Phase 1: local score computation. PE 0 stages local_max into
    // scratch_out and fires the chain east; other PEs arm an async
    // recv that activates reduce_recv when the wavelet arrives from
    // the west. The width=1 case (pe_id == 0 and pe_id == num_pes-1
    // simultaneously) skips the chain entirely and goes straight to
    // normalize with global_max = local_max.
    try W.write(buf, pos, "fn compute() void {\n");
    try W.write(buf, pos, "    local_max = -3.4028235e+38;\n");
    try W.write(buf, pos, "    local_sum = 0.0;\n");
    try emitScoreLoop(buf, pos, q, k, "kv_chunk");
    try W.write(buf, pos, "    if (num_pes == 1) {\n");
    try W.write(buf, pos, "        global_max = local_max;\n");
    try W.write(buf, pos, "        @activate(norm_task_id);\n");
    try W.write(buf, pos, "    } else if (pe_id == 0) {\n");
    try W.write(buf, pos, "        scratch_out[0] = local_max;\n");
    try W.write(buf, pos, "        @mov32(reduce_out, scratch_out_dsd, .{ .async = true });\n");
    try W.write(buf, pos, "    } else {\n");
    try W.write(buf, pos, "        @mov32(scratch_in_dsd, reduce_in, .{ .async = true, .activate = reduce_task_id });\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "}\n\n");

    // Phase 2: task fires on async recv completion. scratch_in[0]
    // carries the running max from the west. Combine with local
    // state, forward east on non-last PEs, or activate normalize on
    // the last PE.
    try W.write(buf, pos, "task reduce_recv() void {\n");
    try W.write(buf, pos, "    const incoming = scratch_in[0];\n");
    try W.write(buf, pos, "    if (incoming > global_max) global_max = incoming;\n");
    try W.write(buf, pos, "    const best = (if (local_max > global_max) local_max else global_max);\n");
    try W.write(buf, pos, "    if (pe_id != num_pes - 1) {\n");
    try W.write(buf, pos, "        scratch_out[0] = best;\n");
    try W.write(buf, pos, "        @mov32(reduce_out, scratch_out_dsd, .{ .async = true });\n");
    try W.write(buf, pos, "    } else {\n");
    try W.write(buf, pos, "        global_max = best;\n");
    try W.write(buf, pos, "        @activate(norm_task_id);\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "}\n\n");

    try W.write(buf, pos, "task normalize() void {\n");
    try W.write(buf, pos, "    for (@range(i16, head_dim)) |d| { ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, d)] = 0.0; }\n");
    try W.write(buf, pos, "    var sum_exp: f32 = 0.0;\n");
    try W.write(buf, pos, "    for (@range(i16, kv_chunk)) |kv_i| {\n");
    try emitSlidingWindowGuard(buf, pos, "        ", "kv_i");
    try W.write(buf, pos, "        var score: f32 = 0.0;\n");
    try W.write(buf, pos, "        for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "            score += ");
    try W.write(buf, pos, q);
    try W.write(buf, pos, "[@as(u32, d)] * ");
    try W.write(buf, pos, k);
    try W.write(buf, pos, "[@as(u32, kv_i) * @as(u32, head_dim) + @as(u32, d)];\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        score *= scale;\n");
    try W.write(buf, pos, "        const w = math.exp(score - global_max);\n");
    try W.write(buf, pos, "        sum_exp += w;\n");
    try W.write(buf, pos, "        for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "            ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, d)] += w * ");
    try W.write(buf, pos, v);
    try W.write(buf, pos, "[@as(u32, kv_i) * @as(u32, head_dim) + @as(u32, d)];\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "    const inv = 1.0 / sum_exp;\n");
    try W.write(buf, pos, "    for (@range(i16, head_dim)) |d| { ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, d)] *= inv; }\n");
    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");

    try W.write(buf, pos, "comptime {\n");
    try W.write(buf, pos, "    @bind_local_task(reduce_recv, reduce_task_id);\n");
    try W.write(buf, pos, "    @bind_local_task(normalize, norm_task_id);\n");
    try W.write(buf, pos, "    if (@is_arch(\"wse3\")) {\n");
    try W.write(buf, pos, "        @initialize_queue(reduce_out_q, .{ .color = reduce_color });\n");
    try W.write(buf, pos, "        @initialize_queue(reduce_in_q, .{ .color = reduce_color });\n");
    try W.write(buf, pos, "    }\n");
    // Layout owns reduce_color routing; wse3 rejects a second PE-local
    // color config for the same color.
    try emitStorageExports(buf, pos, module);
    try emitDecodeRuntimeExports(buf, pos);
    try W.write(buf, pos, "    @export_symbol(compute);\n");
    try W.write(buf, pos, "}\n");
}

// ---------------------------------------------------------------------------
// Tiled attention — Flash Attention with tile broadcasts
// ---------------------------------------------------------------------------

pub fn emitTiled(
    buf: []u8,
    pos: *usize,
    module: *const ir.Module,
    info: classify.AttentionTiledInfo,
) EmitError!void {
    const q = module.globals.items[info.q_global].name;
    const k = module.globals.items[info.k_global].name;
    const v = module.globals.items[info.v_global].name;
    const out = module.globals.items[info.output_global].name;

    try W.write(buf, pos, "// PE program: tiled Flash Attention for prefill (streaming KV).\n");
    try W.write(buf, pos, "// Host streams K/V block-by-block into the exported k/v buffers,\n");
    try W.write(buf, pos, "// launching `compute_tile` once per tile; a final `finalize` pass\n");
    try W.write(buf, pos, "// normalizes the accumulated output. See\n");
    try W.write(buf, pos, "// bench/out/cslc-attn-streaming-probe/probe-result.json for the\n");
    try W.write(buf, pos, "// per-PE feasibility map that drives the host-chosen\n");
    try W.write(buf, pos, "// (block_size, q_len_per_pe) sizing.\n\n");

    try W.write(buf, pos, "param memcpy_params;\n");
    try W.write(buf, pos, "param head_dim: i16;\n");
    // block_size now names the streaming tile (host iteration unit), not
    // the inner-loop chunk of a PE-resident KV matrix. Default 16 matches
    // head_dim=256 feasibility; head_dim=512 hosts override to 4.
    try W.write(buf, pos, "param block_size: i16 = 16;\n");
    // q_len_per_pe shards q_len across the width dim of the layout.
    // Defaults to q_len so a width=1 layout collapses to the full query.
    try W.write(buf, pos, "param q_len: i16;\n");
    try W.write(buf, pos, "param q_len_per_pe: i16 = q_len;\n");
    try W.write(buf, pos, "param scale: f32 = 0.125;\n\n");

    try W.write(buf, pos, "const sys_mod = @import_module(\"<memcpy/memcpy>\", memcpy_params);\n");
    try W.write(buf, pos, "const math = @import_module(\"<math>\");\n\n");

    // Storage sizing:
    //   q / out — q_len_per_pe × head_dim (per PE's shard of the query/output)
    //   k / v   — block_size × head_dim (tile window; overwritten per host iteration)
    try emitTiledStoragePtrs(buf, pos, module);

    // Online softmax state, per-query-row, preserved across compute_tile calls.
    try W.write(buf, pos, "var m_state: [q_len_per_pe]f32 = @zeros([q_len_per_pe]f32);\n");
    try W.write(buf, pos, "var l_state: [q_len_per_pe]f32 = @zeros([q_len_per_pe]f32);\n\n");
    try W.write(buf, pos, "var score_cache: [block_size]f32 = @zeros([block_size]f32);\n\n");

    // compute: named `compute` to satisfy the csl_spec structural marker
    // that every emitted PE program must export a `compute` symbol.
    // Streaming semantics: consume the current k/v tile contents and update
    // (output, m_state, l_state). Host dispatches it once per tile.
    try W.write(buf, pos, "fn compute() void {\n");
    try W.write(buf, pos, "    for (@range(i16, q_len_per_pe)) |qi| {\n");
    try W.write(buf, pos, "        var m_i: f32 = m_state[@as(u32, qi)];\n");
    try W.write(buf, pos, "        var l_i: f32 = l_state[@as(u32, qi)];\n");
    try W.write(buf, pos, "        var blk_max: f32 = -3.4028235e+38;\n");
    try W.write(buf, pos, "        for (@range(i16, block_size)) |bi| {\n");
    try W.write(buf, pos, "            var score: f32 = 0.0;\n");
    try W.write(buf, pos, "            for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "                score += ");
    try W.write(buf, pos, q);
    try W.write(buf, pos, "[@as(u32, qi) * @as(u32, head_dim) + @as(u32, d)]\n");
    try W.write(buf, pos, "                    * ");
    try W.write(buf, pos, k);
    try W.write(buf, pos, "[@as(u32, bi) * @as(u32, head_dim) + @as(u32, d)];\n");
    try W.write(buf, pos, "            }\n");
    try W.write(buf, pos, "            score *= scale;\n");
    try W.write(buf, pos, "            score_cache[@as(u32, bi)] = score;\n");
    try W.write(buf, pos, "            if (score > blk_max) blk_max = score;\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        const m_new = (if (m_i > blk_max) m_i else blk_max);\n");
    try W.write(buf, pos, "        const rescale = math.exp(m_i - m_new);\n");
    try W.write(buf, pos, "        l_i *= rescale;\n");
    try W.write(buf, pos, "        for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "            ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, qi) * @as(u32, head_dim) + @as(u32, d)] *= rescale;\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        for (@range(i16, block_size)) |bi| {\n");
    try W.write(buf, pos, "            const w = math.exp(score_cache[@as(u32, bi)] - m_new);\n");
    try W.write(buf, pos, "            l_i += w;\n");
    try W.write(buf, pos, "            for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "                ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, qi) * @as(u32, head_dim) + @as(u32, d)]\n");
    try W.write(buf, pos, "                    += w * ");
    try W.write(buf, pos, v);
    try W.write(buf, pos, "[@as(u32, bi) * @as(u32, head_dim) + @as(u32, d)];\n");
    try W.write(buf, pos, "            }\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        m_state[@as(u32, qi)] = m_new;\n");
    try W.write(buf, pos, "        l_state[@as(u32, qi)] = l_i;\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");

    // finalize: normalize output by accumulated l_state. Called once by
    // the host after all tiles are consumed.
    try W.write(buf, pos, "fn finalize() void {\n");
    try W.write(buf, pos, "    for (@range(i16, q_len_per_pe)) |qi| {\n");
    try W.write(buf, pos, "        const inv = 1.0 / l_state[@as(u32, qi)];\n");
    try W.write(buf, pos, "        for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "            ");
    try W.write(buf, pos, out);
    try W.write(buf, pos, "[@as(u32, qi) * @as(u32, head_dim) + @as(u32, d)] *= inv;\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "    }\n");
    try W.write(buf, pos, "    sys_mod.unblock_cmd_stream();\n");
    try W.write(buf, pos, "}\n\n");

    try emitTiledComptime(buf, pos, module);
}

// Tiled-attention-specific storage sizing: q/out sized by q_len_per_pe
// (the per-PE query shard) and k/v sized by block_size (the host-streamed
// tile window). Distinct from emitStoragePtrs, which sizes K/V by the full
// kv_len and does not fit manifest-scale PE memory.
fn emitTiledStoragePtrs(buf: []u8, pos: *usize, module: *const ir.Module) EmitError!void {
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        const size_expr: []const u8 = if (isKvStorageName(global.name))
            "block_size * head_dim"
        else
            "q_len_per_pe * head_dim";
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ": [");
        try W.write(buf, pos, size_expr);
        try W.write(buf, pos, "]f32 = @zeros([");
        try W.write(buf, pos, size_expr);
        try W.write(buf, pos, "]f32);\n");
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, "_ptr: [*]");
        try writeScalarType(buf, pos, module, global.ty);
        try W.write(buf, pos, " = &");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ";\n");
    }
    try W.write(buf, pos, "\n");
}

fn emitTiledComptime(buf: []u8, pos: *usize, module: *const ir.Module) EmitError!void {
    try W.write(buf, pos, "comptime {\n");
    try emitStorageExports(buf, pos, module);
    try W.write(buf, pos, "    @export_symbol(compute);\n");
    try W.write(buf, pos, "    @export_symbol(finalize);\n");
    try W.write(buf, pos, "}\n");
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn emitScoreLoop(buf: []u8, pos: *usize, q: []const u8, k: []const u8, len_param: []const u8) EmitError!void {
    try W.write(buf, pos, "    for (@range(i16, ");
    try W.write(buf, pos, len_param);
    try W.write(buf, pos, ")) |kv_i| {\n");
    try emitSlidingWindowGuard(buf, pos, "        ", "kv_i");
    try W.write(buf, pos, "        var score: f32 = 0.0;\n");
    try W.write(buf, pos, "        for (@range(i16, head_dim)) |d| {\n");
    try W.write(buf, pos, "            score += ");
    try W.write(buf, pos, q);
    try W.write(buf, pos, "[@as(u32, d)] * ");
    try W.write(buf, pos, k);
    try W.write(buf, pos, "[@as(u32, kv_i) * @as(u32, head_dim) + @as(u32, d)];\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        score *= scale;\n");
    try W.write(buf, pos, "        if (score > local_max) {\n");
    try W.write(buf, pos, "            const rescale = math.exp(local_max - score);\n");
    try W.write(buf, pos, "            local_sum *= rescale;\n");
    try W.write(buf, pos, "            local_max = score;\n");
    try W.write(buf, pos, "        }\n");
    try W.write(buf, pos, "        local_sum += math.exp(score - local_max);\n");
    try W.write(buf, pos, "    }\n");
}

fn emitSlidingWindowGuard(buf: []u8, pos: *usize, indent: []const u8, loop_var: []const u8) EmitError!void {
    try W.write(buf, pos, indent);
    try W.write(buf, pos, "if (decode_sliding_window[0] > 0) {\n");
    try W.write(buf, pos, indent);
    try W.write(buf, pos, "    const current_pos = decode_position[0];\n");
    try W.write(buf, pos, indent);
    try W.write(buf, pos, "    const sliding_window = decode_sliding_window[0];\n");
    try W.write(buf, pos, indent);
    try W.write(buf, pos, "    const abs_key = @as(u32, pe_id) * @as(u32, kv_chunk) + @as(u32, ");
    try W.write(buf, pos, loop_var);
    try W.write(buf, pos, ");\n");
    try W.write(buf, pos, indent);
    try W.write(buf, pos, "    if (current_pos >= sliding_window and abs_key < current_pos - sliding_window + 1) continue;\n");
    try W.write(buf, pos, indent);
    try W.write(buf, pos, "}\n");
}

fn emitDecodeRuntimeState(buf: []u8, pos: *usize) EmitError!void {
    try W.write(buf, pos, "var decode_position: [1]u32 = @zeros([1]u32);\n");
    try W.write(buf, pos, "var decode_position_ptr: [*]u32 = &decode_position;\n");
    try W.write(buf, pos, "var decode_sliding_window: [1]u32 = @zeros([1]u32);\n");
    try W.write(buf, pos, "var decode_sliding_window_ptr: [*]u32 = &decode_sliding_window;\n\n");
}

fn emitDecodeRuntimeExports(buf: []u8, pos: *usize) EmitError!void {
    try W.write(buf, pos, "    @export_symbol(decode_position_ptr, \"position\");\n");
    try W.write(buf, pos, "    @export_symbol(decode_sliding_window_ptr, \"sliding_window\");\n");
}

fn emitStoragePtrs(buf: []u8, pos: *usize, module: *const ir.Module) EmitError!void {
    // CSL rejects `var x: [*]f32 = undefined;` (and `&x` on a pointer
    // yields a pointer-to-pointer, not [*]f32). Use the sized-array +
    // aliased-pointer pattern the elementwise / rope / gather /
    // linear-attn emitters use. Size heuristic by name:
    //   K / V names   → [kv_len * head_dim]f32     (full KV matrix)
    //   Q / O names   → [q_len * head_dim]f32      (query / output rows)
    //   fallback      → [q_len * head_dim]f32      (safe upper bound)
    // The access patterns in emitTiled / emitStreaming stay in-bounds
    // for these sizes.
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        const size_expr: []const u8 = if (isKvStorageName(global.name))
            "kv_len * head_dim"
        else
            "q_len * head_dim";
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ": [");
        try W.write(buf, pos, size_expr);
        try W.write(buf, pos, "]f32 = @zeros([");
        try W.write(buf, pos, size_expr);
        try W.write(buf, pos, "]f32);\n");
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, "_ptr: [*]");
        try writeScalarType(buf, pos, module, global.ty);
        try W.write(buf, pos, " = &");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ";\n");
    }
    try W.write(buf, pos, "\n");
}

fn emitDecodeStoragePtrs(buf: []u8, pos: *usize, module: *const ir.Module) EmitError!void {
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        const size_expr: []const u8 = if (isKvStorageName(global.name))
            "kv_chunk * head_dim"
        else
            "head_dim";
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ": [");
        try W.write(buf, pos, size_expr);
        try W.write(buf, pos, "]f32 = @zeros([");
        try W.write(buf, pos, size_expr);
        try W.write(buf, pos, "]f32);\n");
        try W.write(buf, pos, "var ");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, "_ptr: [*]");
        try writeScalarType(buf, pos, module, global.ty);
        try W.write(buf, pos, " = &");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, ";\n");
    }
    try W.write(buf, pos, "\n");
}

fn isKvStorageName(name: []const u8) bool {
    // A kernel's K and V buffers hold the full kv_len rows. Q and O
    // only hold q_len rows. Conservative: default to q_len sizing when
    // unrecognized, since kv_len is typically >= q_len in decode.
    return std.mem.indexOf(u8, name, "K") != null or
        std.mem.indexOf(u8, name, "V") != null or
        std.mem.indexOf(u8, name, "key") != null or
        std.mem.indexOf(u8, name, "val") != null or
        std.mem.indexOf(u8, name, "_k") != null or
        std.mem.indexOf(u8, name, "_v") != null;
}

fn emitStorageExports(buf: []u8, pos: *usize, module: *const ir.Module) EmitError!void {
    for (module.globals.items) |global| {
        if (global.binding == null) continue;
        const space = global.addr_space orelse continue;
        if (space != .storage) continue;
        try W.write(buf, pos, "    @export_symbol(");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, "_ptr, \"");
        try W.write(buf, pos, global.name);
        try W.write(buf, pos, "\");\n");
    }
}

fn emitComptime(buf: []u8, pos: *usize, module: *const ir.Module) EmitError!void {
    try W.write(buf, pos, "comptime {\n");
    try emitStorageExports(buf, pos, module);
    try W.write(buf, pos, "    @export_symbol(compute);\n");
    try W.write(buf, pos, "}\n");
}

fn writeScalarType(buf: []u8, pos: *usize, module: *const ir.Module, ty: ir.TypeId) EmitError!void {
    const resolved = module.types.get(ty);
    switch (resolved) {
        .scalar => |scalar| try W.write(buf, pos, spec.scalarTypeName(scalar)),
        .array => |array| try writeScalarType(buf, pos, module, array.elem),
        else => try W.write(buf, pos, "u32"),
    }
}
