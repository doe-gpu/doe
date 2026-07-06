# Doe status: Cerebras and CSL

This is a live topical status shard. Follow the shared shard policy in
[`README.md`](README.md).

Current queue summary lives in `docs/cerebras-model-ledgers.md`. Older entries
below are historical status, including the WS4 memory-blocker framing. The
active Gemma 4 31B af16 blocker is real-session token/logit/KV transcript
completion.

## Lane status

Lane verdicts and blockers are not restated in this doc. The status snapshot
documented in [`../cerebras.md`](../cerebras.md) reads
receipts directly and writes
`bench/out/r3-cerebras-status/snapshot.{md,json}`. Every row points at the
underlying artifact and shows its mtime. Refresh the snapshot whenever you want
the current truth.

This doc retains dated context entries (architecture, named blockers,
follow-up work) below. Numbers, verdicts, and "which launch are we on"
belong in the snapshot, never here.

Sharding follow-up: owner Doe Cerebras; split the remaining HostPlan runtime
subprocess/checkpoint launch loop out of
`bench/runners/csl-runners/int4ple_compile_target_sim_runner.py`.

Contract note: `doe-transcript-parity-report` schema v2 makes generated-token
exact parity and logits comparison status explicit. `max_abs` is the Doppler
tolerance-backed logits gate unless a reference export declares
`sha256_exact`.

## 2026-07-05 — Qwen no-hardware readiness classification gate

`bench/tools/cerebras_status_snapshot.py` now emits `localReadiness` for the
Qwen pre-hardware lane. The full-prompt hardware row is typed as
`hardware_required` with `hardware_endpoint_required` when the returned WSE
trace is absent; local blockers remain local blockers with their existing
artifact rows.

`python3 bench/tools/check_cerebras_no_hardware_readiness.py` gates that
classification. Passing the gate means the local evidence and remaining gaps
are typed for operator handoff. It is not a hardware execution claim and does
not promote `qwen.hardware_full_prompt`.

## 2026-06-16 — HostPlan execution-plan materialization sharded

`bench/runners/csl-runners/int4ple_hostplan_execution_plan.py` now keeps the
final execution-plan builder and compatibility exports. Metadata/common
parsing, tensor transform rules, binding materialization, and buffer planning
live in focused `int4ple_hostplan_execution_*` modules.

## 2026-06-16 — 31B af16 HostPlan front door sharded

`bench/runners/csl-runners/gemma4_31b_af16_hostplan_streaming_runner.py` now
keeps CLI parsing, per-kernel refresh, evidence-gate evaluation, and final
trace assembly. Shared constants/path helpers and the weight-staging plus
dispatch-planning logic live in focused `gemma4_31b_af16_hostplan_*` modules.

## 2026-06-16 — 31B af16 session runtime sharded

`bench/runners/csl-runners/gemma4_31b_af16_session_runtime.py` is now a
compatibility facade. Shared constants/path helpers, weight mappings and
reference requests, scheduler assembly, and runtime/checkpoint/transcript
execution live in focused `gemma4_31b_af16_session_*` modules. The checkpoint
identity now hashes the facade plus split helper modules so runtime-version
drift is still detected after the split.

## 2026-06-16 — E2B self-check contracts sharded

`bench/tools/e2b_layer_block_self_check.py` now stays focused on step
orchestration and dispatches receipt, model, demo tooling, and evidence-bundle
contract assertions through focused modules. The E2B layer-block sharding
follow-up is closed.

## 2026-05-06 — Gemma and Qwen CSL tail checks widened

The selected-logit splice scripts for Gemma 4 31B and Qwen 3.6 27B now move
final RMSNorm into CSL before replaying selected lm-head candidate rows. The
receipts record final-norm diff, candidate-count, selected-logit diff, decision
margin, and the strict-logit-tolerance verdict. The proof remains scoped to the
selected candidate set and top-token decision; full-vocabulary logits and full
decoder-layer replay still require the graph execution path.

## 2026-05-06 — Qwen full-prompt hardware path packaged

Qwen now has the same operator surface as the Gemma af16 HostPlan lane:
`bench/tools/run_qwen3_6_27b_af16_hardware_path.sh` fetches the hosted
`Clocksmith/rdrr` Qwen af16 manifest plus shared Q4K weight pack, verifies the
evidence archive, compiles the bundled HostPlan source, and launches
`bench/runners/csl-runners/qwen3_6_27b_af16_hostplan_streaming_runner.py`
against the endpoint. The tracked HostPlan source fixture is
`bench/fixtures/cerebras-hostplans/qwen3-6-27b-af16/`.

The local no-hardware probe is
`bench/tools/run_qwen3_6_27b_af16_local_simfabric_ceiling.py`; when run it
writes `bench/out/r3-2-27b-af16-local-simfabric-ceiling/receipt.json` with the
first observed local HostPlan blocker. Returned hardware traces land under
`bench/out/hardware-run/qwen3-6-27b-af16-*` and are reflected by
`bench/tools/cerebras_status_snapshot.py`.

## 2026-05-06 — Qwen Doppler to CSL splice bound

Qwen now has the same local bridge proof class as Gemma's selected-logit lane.
`bench/tools/run_qwen_3_6_27b_af16_doppler_selected_logit_splice.py`
loads Doppler's final-layer `post_ffn` fixture for
`The color of the sky is`, runs Qwen final RMSNorm in CSL with the manifest's
weight-offset rule, reads the selected real `lm_head.weight` rows from Q4_K_M
storage, dequantizes those rows to the CSL cell input dtype, and runs the
selected dense lm-head dots through CSL chunks.

Receipt:
`bench/out/r3-2-27b-af16-doppler-csl-splice/selected-logit-splice/selected-logit-splice.json`.
The claim remains deliberately narrow: selected candidate logits and top-token
decision only, not full-vocabulary argmax, not layer-63 replay, and not
hardware execution.

## 2026-05-04 — Phase 4/5 blockers cleared (qwen gemv task-id, gemma af16 lm_head cell)

Two compact-gate blockers from the morning's compile-only bind landed.

**Qwen GEMV collectives task-id collision.** `cslc` reports the local
task-id reserved range as `[8,31)`; `id=12` collided with the
`<collectives_2d>` reserved band. Rebound `reduce_done_id` from 12 to 13
in `bench/runners/csl-runners/qwen-3-6-27b-cells/gemv_pe_program.csl`
(one-line change; companion edit in `gemv_layout.csl`). Canary compile
with `width:2,height:1,out_dim:4,out_dim_per_pe:4,in_dim_per_pe:512,
num_blocks_per_row:2` succeeds.

**Gemma af16 `lm_head` cell triple authored.** New
`bench/runners/csl-runners/gemma-4-31b-af16-cells/{lm_head_layout.csl,
lm_head_pe_program.csl, lm_head_run.py}` mirroring the qwen dense GEMV +
`collectives_2d` reduce pattern, adapted to f16 vocab/hidden shape.
Local canary parity passes on simfabric. This is the input the Phase 4
`gemma af16 bounded smoke receipt` synth needs to clear
`dispatch_evidence_lm_head_unbound`
(`bench/tools/_inference_evidence_gate.py`).

Phase 4/5 ladder bookkeeping (run via `tools/run-phase4-5.sh` from
`dc9bb86` + hardening in `581de92`): 9/10 qwen cells green pre-fix
(gemv was the failure), all 10 green post-fix; phase5 frozen Doppler
validators both pass for Gemma and Qwen. Eleven `phase4 qwen gemv
compile-attempt verbose` retries traced the task-id collision before
the rebind landed. The 80G `MemoryMax` cap held throughout — no OOM
events, no host stalls.

Next: regenerate the Gemma af16 bounded smoke receipt now that
`lm_head` has a bound dispatch verdict, then re-run the Phase 6
cross-model aggregate. Phase 7 (full BOS sky session, hardware
receipts) remains gated on the runtime correctness ladder, not on
this bind.

## 2026-05-04 — Compact correctness gate bound (compile-only)

The four-lane compact correctness gate
(`bench/out/r3-cross-model-parity/receipt.json`) is at **`verdict=bound`**,
`laneBound=4/4`, `issues=[]`. Receipt hash:
`92fcb6b209068422ad5fb2e6b7a35b0d08b03432b9176ae6d73737670de2cb9d`. All four
required lanes — `gemma4_31b_af32`, `gemma4_31b_af16`, `qwen3_6_27b_af32`,
`qwen3_6_27b_af16` — bind.

Gemma af16 unblock: the monolithic `lm_head_prefill` target was split
into six smaller `lm_head_prefill_width_tile_x*_w32` tiles (steps
14–19 of the 23-target plan). All 23 compile targets succeeded under the
80G `MemoryMax` cap with `compileFailedCount=0`. Tiles 14–16 plateaued in
the 58–61G band; tiles 17–19 in the 18–21G band; zero swap throughout.

Two follow-on tooling fixes verified:

- `bench/tools/predict_simfabric_wallclock.py` now understands one logical
  kernel backed by tiled compile targets;
  `python3 -m unittest bench.tests.test_predict_simfabric_wallclock` passed.
- `bench/tools/aggregate_cross_model_parity.py` now resolves the cslc
  wrapper to the underlying compiler for toolchain hash comparison while
  preserving wrapper metadata.

**Scope clarification.** This bind covers the compile-only fixture: the full
compile inventory for the generated inference host plan plus the cross-model
correctness aggregate. The `run` phase still reports `compile_only_fixture`,
which is the intended output for this gate. Runtime/inference correctness is
the next ladder (Phase 4–5 bounded CSL cells + minimal host skeleton, with
Doppler / Doe Vulkan as the semantic oracle), NOT covered by this receipt.

Plan + agent rules: `.agents/cerebras-compact-correctness-gate-7phase.md`.

## 2026-05-03 — Gemma 4 31B simfabric hardware hold

The Gemma 4 31B af16 `<bos>sky color is` simfabric session is stopped on a
clean checkpoint after `launch-0022` (`attn_small`) succeeded through the
compact-width attention path. See
`bench/out/r3-1-31b-af16-hostplan-postmortem/launch-postmortem-2026-05-03.json`
for the checkpoint state, execution-plan launch count, target mix, Q4K shard
summary, and receipt paths.

The active blocker is architectural simfabric D2H serialization on this host,
not a HostPlan identity or checkpoint-corruption issue. Q4K stayed on the
known-safe serial settings (`jobs=1`, `adapterStepBudget=1`,
`outputPeRows=4`); attempted Q4K process/thread/step-budget expansion remains
non-claimable because it stalls in the SDK D2H path. Hardware endpoint access
(R2-10) is the unblock for closing the full real-session token/logit/KV
transcript.

The canonical relaunch command is
`bench/out/scratch/run-next-session-parallel.sh`. It keeps Q4K serial, enables
compact prefill attention, and carries the unit-validated embed ROI lane plus
the configured lm-head runtime lane. The command is runtime-proven through
`launch-0022`; the killed `launch-0023` Q4K partial did not commit a receipt
and the checkpoint manifest remains at the prior launch boundary.

## 2026-05-02 — CSL emitter performance audit: scalar dot products vs fmacs+DSD

A side-by-side pass over `runtime/zig/src/doe_wgsl/emit_csl_*.zig` against the
canonical SUMMA GEMM and GEMV-collectives_2d references identified a
consistent gap: the matmul emitter uses the canonical `@fmacs` over a
`mem1d_dsd` inner pattern, but GEMV, fused FFN, and all three attention paths
fall through to scalar `for` loops over the contracted dimension. Per the CSL
technical overview, the PE datapath is four FP16 FMAC units behind the DSR
file; scalar fp32 mul-add cannot saturate it. This is the largest source of
emitter-side speed left on the table before WSE-3 evidence.

The audit also surfaced two redundant-work patterns and a linear chain reduce
that should be a tree, plus a few low-severity cleanups. Items already in
flight (Qwen GEMV reduce switched to `reduce_fadds` 2026-04-28; Q4K-input
SUMMA prototype landed 2026-04-27) are noted but not re-listed.

### High severity — scalar inner loops should be `@fmacs` over `mem1d_dsd`

The canonical pattern, already shipping in `emit_csl_matmul.zig:143-153`:

```
for (@range(i16, Kt)) |k| {
    var C_dsd = @get_dsd(mem1d_dsd, ...);
    for (@range(i16, Nt)) |j| {
        @fmacs(C_dsd, C_dsd, A_dsd, b_val);
        C_dsd = @increment_dsd_offset(C_dsd, Mt, f32);
    }
    A_dsd = @increment_dsd_offset(A_dsd, Mt, f32);
}
```

Targets to migrate:

1. **`emit_csl_dense_gemv.zig:82-91`** — `for row { for col { sum += act[col]
   * weight[idx] } }`. Inner loop is a scalar fp32 mul-add over
   `in_dim_per_pe`; should be `@fmacs(partial_dsd, partial_dsd,
   weight_row_dsd, act[col])` with `weight_row_dsd` as a strided
   `mem1d_dsd` over the row.
   Started 2026-05-02 — Q4K GEMV hot path in `emit_csl_fused.zig` migrated
   from row-scalar dot loops to a DSD `@fmacs` shape over `weight_col` and
   `partial` vectors (this is the launch-14 bottleneck path). Pending
   regenerate + CSL recompile for verification. `emit_csl_dense_gemv.zig`
   itself still scalar; non-Q4K attention score loops (items 3, 4, 5) also
   still scalar.
2. **`emit_csl_fused_ffn.zig:60-77`** — same scalar shape on both
   `gate_sum` and `up_sum`. Two parallel fmacs over the same `in_per_pe`
   contraction.
3. **`emit_csl_attention.zig::emitStreaming` (lines 99-107, 124-129)** — QK
   score loop is scalar over `head_dim`.
4. **`emit_csl_attention.zig::emitDecode::emitScoreLoop` (lines 467-488)** —
   same.
5. **`emit_csl_attention.zig::emitTiled` (lines 360-368, 381-389)** — same,
   plus issue 6 below.

### High severity — redundant work and serial reduces

6. **`emit_csl_attention.zig::emitTiled` recomputes the QK dot product** —
   the inner block first computes `score` to find `blk_max`, then recomputes
   the same `score` in the second loop to weight V. Cache scores in a
   `[block_size]f32` scratch on pass 1; pass 2 reuses. With
   `block_size=16, head_dim=256` that is ~4 KiB scratch saving ~4096
   redundant mul-adds per query row per tile.
   Done 2026-05-02; tiled attention now stores scaled block scores in
   `score_cache: [block_size]f32` during the max pass and reuses those
   values for the value-weighting pass. This removes the second QK dot
   loop while preserving the streaming K/V tile host contract.
7. **`emit_csl_attention.zig::emitStreaming` runs a 2-pass softmax** —
   max-find then weight-and-sum. The decode path already has a correct
   online-softmax shape in `emitScoreLoop`; port it to streaming.
   Done 2026-05-02; rewrote `compute()` to single-pass online softmax
   with running `(m, l)` and rescale-on-new-max, also folding the
   output accumulation into the same loop. Eliminates the redundant
   second QK dot product. Streaming path is for Qwen
   linear_attention which is currently scope-restricted, so no active
   parity surface affected.
8. **`emit_csl_fused_ffn.zig:84-97` reduces one element at a time over
   fabric** — `reduce_recv` task fires per output element with
   `fabout_dsd { extent = 1 }`. For Gemma `out_dim ≈ 2304` that is 2304+
   task fires per layer per FFN. Switch to the same
   `mpi_x.reduce_fadds(...)` over a full partial-vector DSD that
   `emit_csl_dense_gemv.zig:99` already uses (the canonical pattern landed
   for the GEMV lane on 2026-04-28).
   Done 2026-05-02; `emit_csl_fused_ffn.zig` now reduces the full
   `gate_partial` and `up_partial` vectors with `collectives_2d`
   `mpi_x.reduce_fadds`, then applies SiLU on the row root. The layout now
   passes per-tile `c2d_params` and removes the hand-routed reduce color, so
   width greater than two follows the canonical collective shape instead of
   the known-gap row chain.
9. **`emit_csl_attention.zig::emitDecode::reduce_recv` is a linear chain
   reduce** — the local-max propagates east hop-by-hop, O(width) wavelets.
   Switch to `mpi_x.reduce_max` (or chain through `collectives_2d` reduce
   primitives) for O(log width). Material at width ≥ 32; significant at
   WSE-3 row widths.

### Medium severity — acknowledged in source comments

10. **f32 SUMMA broadcast inflation** — `emit_csl_matmul.zig` self-notes
    "~7× more bytes than necessary"; `emit_csl_matmul_q4k.zig` is the
    landed fix for the Q4K-input lane (2026-04-27 entry). The af32
    activation lane on the f32 SUMMA path still sends 4× more bytes than
    a f16 broadcast would. Open follow-up: an f16-input SUMMA emitter
    that mirrors the Q4K prototype.
11. **KV-resident attention exceeds PE memory at `head_dim ≥ 256`** —
    `emit_csl_attention.zig:16-50` documents a 147 KiB / 294 KiB .bss
    footprint vs ~63 KiB PE budget. `emitTiled` with block streaming is
    the fix and lives in the same file; the older `emitStreaming` /
    `emitDecode` paths still allocate full KV per PE. Migrate the callers,
    then drop the old paths.

### Low severity — cleanups

12. **`emit_csl_rmsnorm_pack.zig:3-4`** — `CHUNK_COUNT = 21` is a hard
    constant sized for the largest target hidden_size. Smaller models pay
    a dozen stub `@export_name` / `@export_symbol` pairs per call and a
    per-chunk `else { ...[word] = 0; }` write inside the pack loop.
    Derive `CHUNK_COUNT` from the manifest's hidden_size at emit time.
13. **`emit_csl_dense_gemv.zig:88`** — `@as(f32, activation[col]) *
    @as(f32, weight[idx])` widens fp16 to fp32 on every multiply.
    Pre-widen the activation row once, or use `@fmach` over fp16 DSDs
    (compounds with item 1).
    Done 2026-05-02; added module-scope `activation_f32: [in_dim_per_pe]f32`
    and a one-time pre-widen at the top of `compute()`. Row loop now reads
    `activation_f32[col]` directly. Weight-side widen is left for item 1
    (fmacs over fp16 DSDs).
14. **`emit_csl_rope.zig:77-86`** — `interleaved` is a `param` (comptime
    constant) but the `if (interleaved)` branch lives inside the per-pair
    loop. Hoist as a comptime split so two distinct loop forms emit;
    removes any chance of a per-iteration mispredict.
    Done 2026-05-02; emitter now hoists the branch outside the loop and
    emits two straight-line per-pair loops, one per `interleaved` value.
15. **`emit_csl_dequant.zig:78-79`** — `scales[8]`/`mins[8]` re-zero'd
    inside `dequant_block` per super-block. Stack-allocated so cheap, but
    hoisting them to module-level scratch removes 16 zero-inits per block
    on the dequant-on-broadcast variant.
    Done 2026-05-02; renamed to module-scope `block_scales` /
    `block_mins`, removing the per-call `@zeros([8]f32)` pair.

### Guardrails (added 2026-05-02)

Regression checks landed in `emit_csl_validate.zig` and
`emit_csl_host_compile_source.zig` to keep the new shapes from silently
reverting:

- Fused FFN must emit per-tile `c2d_params` and `mpi_x.reduce_fadds` over
  full partial vectors (not the prior per-element fabric chain). Anchors
  the item-8 fix.
- Tiled attention must emit `score_cache: [block_size]f32` and reuse it on
  the value-weighting pass (no second QK dot). Anchors the item-6 fix.

Verification status: `zig build test-wgsl` passes after the latest
emitter changes; `zig build csl-host-plan-tool` passed before the
`emit_csl_fused.zig` Q4K `@fmacs` edit. The active Q4K compile bundle
needs another regenerate + CSL recompile pass before launch-14 resumes,
since it was rebuilt prior to the GEMV fmacs migration.

### Anchors

Findings grounded against the canonical SDK references:

- GEMM-collectives_2d: <https://sdk.cerebras.net/csl/code-examples/benchmark-gemm-collectives>
- GEMV-collectives_2d: <https://sdk.cerebras.net/csl/code-examples/benchmark-gemv-collectives>
- DSDs: <https://sdk.cerebras.net/csl/language/dsds>
- DSRs: <https://sdk.cerebras.net/csl/language/dsrs>
- SDK technical overview (FP16 FMAC datapath): <https://8968533.fs1.hubspotusercontent-na2.net/hubfs/8968533/Cerebras%20SDK%20Technical%20Overview%20White%20Paper.pdf>

The `emit_csl_matmul.zig` SUMMA emitter is the in-repo reference shape;
items 1-5 are mechanical migrations of that same pattern.

Active prefill Q4K GEMV note, 2026-05-02: the launch-14
`prefill_q4k_gemv` emitter path now uses a DSD `@fmacs` accumulation over a
module-scope `weight_col: [out_dim_per_pe]f32` scratch and the
`partial: [out_dim_per_pe]f32` vector. This keeps the existing Q4K dequant
contract but changes the local accumulation shape from row-scalar dots to a
column-vector FMAC. The generated `tiled_31b` CSL compiles under SDK 2.10 with
the active launch-14 params
`width=84,height=4,out_dim_per_pe=112,in_dim_per_pe=256,num_blocks_per_row=1`.

## Runtime bring-up history

Gemma 4 31B runtime bring-up entries from 2026-04-29 through 2026-05-02 live in `docs/status/cerebras-csl-runtime-bringup.md`.

## 2026-04-28 — Evidence runner blocks stale attention-core receipts

`bench/tools/run_gemma4_e2b_manifest_shape_attention_core.py` now removes the
per-shape output JSON before each SDK subprocess launch and records a typed
failure code when the subprocess cannot produce a fresh receipt. This prevents
an old successful `bench/out/manifest-shape/attention-core/*.json` file from
being loaded after the current SDK invocation fails.

On this host the E2B attention-core lane records
`sdk_container_launch_not_permitted`, so the Cerebras evidence-bundle driver
correctly reports that E2B bundle lane as blocked instead of reusing stale
success evidence. The Gemma 4 31B and Qwen 3.6 27B cross-model compile/parity
receipts remain separate: `bench/out/r3-cross-model-parity/receipt.json`
binds Gemma at 23/23 and Qwen at 19/19 with no accepted compile blockers.

## 2026-04-28 — Qwen cross-model prehardware gate bound with clean compile receipt

The Qwen 3.6 27B compile-step bundle at
`bench/out/r3-2-27b-manifest-fullgraph-compile-steps/` has a current
driver result whose compile section succeeds for every target. The previous
typed blockers for `ssm_linear_attention` and
`attn_prefill_kv_axis_sharded` are closed in the receipt.

The host-plan tool now resolves the checked-in simulator driver correctly
from repo-root invocations. `ssm_linear_attention` shards
`linear_state` with `value_dim_per_pe`, and
`attn_prefill_kv_axis_sharded` derives PE identity from CSL `<layout>`
coordinates rather than per-tile `@set_tile_code` params. `gemv` is
cslc-clean at Qwen shape after the fused GEMV layout reserved both x and y
collectives task-id pairs for SDK `collectives_2d` validation.

`bench/tools/synthesize_qwen_3_6_27b_full_graph_compile_attempt_receipt.py`
now fails closed on stale driver coverage and writes `blocker.class="none"`
when all measured compile verdicts succeed. The joint Gemma/Qwen gate at
`bench/tools/aggregate_cross_model_parity.py` consumes those per-model
compile summaries and writes
`bench/out/r3-cross-model-parity/receipt.json` with `verdict=bound`.

## 2026-04-28 — Qwen SSM body ops bound into exec-v1 smoke config

The Qwen 3.6 27B non-hardware scope now covers the hybrid architecture rather
than only the 16 full-attention layers. The smoke config dispatches the
gated-DeltaNet SSM body sequence with `repeat=48`: `conv1d_depthwise`,
`l2_normalize` for Q/K rows, then `linear_attention`.

The exec-v1 `opToSpec` table routes all three ops to semantic CSL patterns.
`emit_csl_semantic_ops.zig` delegates each PE program to the existing TSIR
body emitters, so the route shares the same math pinned by
`reference_interpreter.zig`: causal depthwise conv, row L2 normalization, and
the shared-norm DeltaNet linear-attention state update. The host-plan tool now
emits compile params and binding metadata for the three SSM body kernels, and
the paired-gate canary pins the new op mapping plus body-program fragments.

## 2026-04-28 — Qwen fused GEMV row reduction switches to collectives_2d

The Qwen 3.6 27B `gemv` width>=3 non-hardware blocker is closed at the Doe
emit surface. The fused GEMV layout no longer hand-configures a `reduce_color`
east-west route. It imports `<collectives_2d/params>`, passes per-tile
`c2d_params` to the PE program, and the PE program imports
`<collectives_2d/pe>` and calls `reduce_fadds` with root `width - 1`.

This keeps SDK source out of the repository while using the SDK's existing
teardown/switch FSM through the normal cslc import path, matching the SUMMA
collectives integration pattern already carried by tiled matmul. The Qwen GEMV
cell fixture mirrors the emitter shape, and the WGSL structural canary pins
that `fused_gemv_dequant` emits collectives imports rather than manual
`@set_color_config` routes.

## 2026-04-27 — Qwen 3.6 27B Doe-side trio lands; typed-blocker chain pinned

The `feat/qwen-3-6-bringup` branch now carries the parallel of the Gemma
4 31B Doe-side evidence trio, all sitting on top of the SUMMA prototype merge:

1. **Smoke config.** `runtime/zig/examples/execution-v1/qwen-3-6-27b-smoke.json`
   mirrors the Gemma 4 31B smoke shape with Qwen's actual numbers: GQA
   24:4, head_dim=256, hidden=5120, intermediate=17408, 64 layers,
   partial-rotary 0.25, queryKeyNorm, attentionOutputGate=swish, SwiGLU
   FFN. `scopeRestrictions` block names three explicit blockers
   (linearAttentionLayers, mropeInterleaved, causalAttentionPrefill).
2. **Synthesizer.** `bench/tools/synthesize_qwen_3_6_27b_full_graph_compile_attempt_receipt.py`
   imports the Gemma synthesizer's residency/classifier helpers and
   only carries Qwen-specific defaults + claim text + scopeRestrictions
   lift from the smoke config. Pre-bundle preflight verified: exits 2
   with the host-plan-tool invocation pointer.
3. **Per-kernel byte-identity test.**
   `bench/tests/test_qwen_3_6_one_layer_per_kernel_byte_identity.py`
   exercises the 1L == 64L per-kernel CSL byte-identity property. Skips with
   typed pointer when the upstream Qwen compile root is absent.
4. **Validator binding test.**
   `bench/tests/test_validate_frozen_qwen_3_6_doppler_reference.py`
   binds the (model-agnostic)
   `bench/tools/validate_frozen_doppler_reference.py` to the Qwen
   fixture path. Skips with typed cross-repo pointer naming the Doppler
   `run-program-bundle-reference.js --tsir-fixture-dir` invocation that
   produces the fixture.

**Trio now exercises the bundle end-to-end at honest scope.** The
smoke config was revised this tick to use ops the host-plan tool
recognizes today (single-input `silu` for FFN activation; the `o_gate`
step is dropped entirely rather than mapped to a non-gated stand-in).
`scopeRestrictions` was extended with `attentionOutputGate` and
`swigluFfnFusedGate` named-blocker entries so the receipts cannot be
misread as covering Qwen's actual gated forms — those need
`silu_gated` / `sigmoid_gated` `KernelPattern` variants + classifier
wiring + opToSpec entries to land before the smoke config can carry
the gated ops. The audit-named TSIR emit-body work is already done on
this branch (see emit_kernel_body_gated.zig); the doe_wgsl classifier
surface is the open downstream blocker.

With the revised smoke config, all three trio legs now run:

- `doe-csl-host-plan-tool` materializes a 15-target Qwen bundle at
  `bench/out/r3-2-27b-manifest-fullgraph-compile-steps/`;
- the per-kernel byte-identity test passes after rematerializing the compile
  root from the current emitter;
- the synthesizer emits
  `bench/out/r3-2-27b-full-graph-compile-attempt/receipt.json` with
  `compileTargetCount=15`, `compileAttempted=true`,
  `compileSucceededCount=10`, `compileFailedCount=1`,
  `scopeRestrictions` lifted from the smoke config.

cslc 2.10.0 ran against each compile dir; 10/11 unique kernels return
`Compilation successful` (embed, rmsnorm, tiled, rope_partial,
residual, silu, gemv, kv_write, attn_decode, sample). The 1 failure is
`attn_prefill` with `failureCode=linker_pe_memory_overflow` — the
same per-PE-residency blocker the Gemma 4 31B prefill ladder carries.
Decode path is fully cslc-clean. The 4 phase-specialized kernel
variants (rmsnorm_prefill/_decode, residual_prefill/_decode) share
CSL byte-identically with their base kernels (verified by the byte-
identity test) and therefore inherit the base verdicts; they are
recorded as `not_attempted` in the receipt's per-target list pending
explicit alias-resolution in the synthesizer.

The rope kernel's `compileParams` now read `head_dim=256, num_pairs=32`
— validating the partial-rotary wiring delta this tick: at Qwen's
manifest `partialRotaryFactor=0.25`, the canonical formula
`head_dim * factor / 2 = 32` rides through correctly (was previously
the kernel-default 64).

Open follow-ups (to make the receipts cite Qwen's actual gated forms,
not stand-ins):
The validator-binding test still depends on Doppler-side capture
(separate cross-repo branch `feat/qwen-3-6-bringup` in the doppler
tree), which is named in the test's typed-skip pointer.

- `silu_gated` / `sigmoid_gated` through the classifier + opToSpec
  chain (KernelPattern variants in emit_csl_classify.zig + WGSL
  pattern-detection branches + opToSpec entries + emit dispatch
  through emit_kernel_body_gated.zig). The TSIR-side work landed on
  this branch; only the doe_wgsl surface remains. Doe-side; unblocks
  the smoke config carrying the actual gated ops.
- Doppler `feat/qwen-3-6-bringup`: capture a deterministic Qwen
  inference run + the TSIR boundary-probe fixture
  (`bench/fixtures/r3-2-27b-doppler-frozen/`).
- cslc invocation against the Qwen bundle (driver-result.json) so the
  synthesizer's `compileAttempted` flips to true and per-target
  failureCode values get attached. Same SDK toolchain dependency the
  Gemma 31B receipts have.
- mropeInterleaved lowering (Qwen-only; deferred until 1D-rotary smoke
  receipts pass).
- Linear-attention layer body op (Qwen 3.6 hybrid; named blocker in
  smoke scopeRestrictions; deferred).
- Causal prefill in `AttentionScoresBody` (shared with Gemma; deferred
  until the prefill simfabric ladder lands).

## 2026-04-27 — Fused-dequant SUMMA prototype (Q4K-input) compiles + executes on simfabric with parity

The `feat/fused-dequant-summa` branch lands the on-PE Q4_K_M dequant SUMMA
prototype end-to-end:

1. **Emitter.** `runtime/zig/src/doe_wgsl/emit_csl_matmul_q4k.zig` produces
   CSL where the B operand is broadcast as raw Q4K bytes and dequanted on
   each PE before the SUMMA fmac inner loop. Layout export at
   `emit_csl_layout.zig::emitMatmulQ4kLayout` types B as `[*]u8` (storage
   index 1). Classifier branch `tiled_matmul_q4k_dequant_b` recognizes the
   pattern (`emit_csl_classify.zig`).
2. **Cell parity.** `bench/out/r2-q4k-fused-dequant-summa/wedge-q4k/run.py`
   drives `cs_python` with cliff-distributed Q4K bytes and compares against
   canonical Doppler dequant + host matmul. Cell receipt
   `bench/out/r2-q4k-fused-dequant-summa/wedge-q4k/receipt.json` records
   `verdict=pass` at P=2 Mt=8 Kt=256 Nt=8 with parity within float32
   precision.
3. **Bound dispatch receipt.** `bench/out/r3-1-31b-multi-token-decode-q4k/`
   carries `mode=compile_and_execute`, hash-links the cell receipt and
   cslc invocation, and records the structural fabric-byte ratio
   (`baselineFabricBytes_f32_dense / wedgeFabricBytes_q4k_block256`).
   `cellParityPassed=true`. Receipt synthesizer
   `bench/tools/synthesize_q4k_summa_dispatch_receipt.py` carries three
   modes: `pending`, `compile_and_execute`, `dispatch`.
4. **Validation gate.** `bench/tests/test_q4k_summa_receipt_parity.py`
   pins the baseline witness, the prototype structural invariants, and the
   compile_and_execute milestone (cell parity flag + tile shape). Dispatch
   parity tests skip until a multi-token decode chain re-runs with
   `b_dtype=.q4k_block256`.

What this is not: not a speed claim (simfabric is correctness-only); not
hardware; not yet bound to Gemma 4 31B's full compile sweep shape. The
small SUMMA cell proves the mechanism. Promotion to manifest-shape SUMMA
is named in the dispatch receipt's `remainingForFullClaim`.

## 2026-04-26 — Per-kernel manifest-shape calibration lands; head_dim=256 attention canary closes; manifest-shape simfabric budget gate flips to allow

Three landings against the manifest-shape simfabric proof plan in
`docs/cerebras-model-ledgers.md`:

1. **Rung 3 calibration via canary-proxy.** Manifest-shape simfabric (246x236
   fabric, ~58k PEs) does not finish a single-kernel dispatch in tractable
   wall-clock on local hosts; the per-kernel `manifest_kernel_probe_runner` times
   out at the chain_step_adapter 1800s timeout. New tool
   `bench/tools/derive_canary_proxy_calibration.py` derives a
   `bytesPerCycle` + `perPatternCyclesPerCall` calibration from the per-kernel
   `bench/out/csl-real-canary-compile/<kernel>/scratch/sim_stats.json` files
   that the bootstrap canary lane already produces (8x3 fabric, ~14
   simulated tiles, finishes in <1s). Receipt class
   `manifest_shape_per_kernel_dispatch_proxy` carries
   `calibrationSource: canary_proxy` and a `claim.notWhat` block naming
   exactly what this is not (manifest-shape evidence). 7/7 tests in
   `bench.tests.test_derive_canary_proxy_calibration`. Replace with a real
   manifest-shape per-kernel dispatch sha256 once hardware execution lands
   (R3-1 / R3-3).

2. **Rung 8 launch gate flips to `allow`.** Rerunning
   `bench/tools/predict_simfabric_wallclock.py` with the canary-proxy
   throughput config produces `calibrated=True`, `bytesPerCycle=0.00449`,
   `grandPredictedCycles=205,502,778`, prefill+decode=
   103,040,639+102,462,139. `config/manifest-simfabric-budget.json` now
   carries the calibration receipt's sha256 in `calibrationStatus` plus
   ceilings at 1.5x predicted. `bench/tools/check_simfabric_budget_gate.py`
   decision: `allow` (was: `deny`). Test
   `test_bootstrap_ceiling_in_repo_denies_with_default_budget_shape` was
   asserting the in-repo ceiling carried the bootstrap token; split into
   two tests covering the uncalibrated-budget and bootstrap-token-in-ceiling
   paths so the in-repo ceiling can carry a real calibration.

3. **Rung 6 partial close: attention canary head_dim=256 routes through
   TSIR-CSL emit body.** New Zig executable
   `runtime/zig/src/main_emit_tsir_attention_canary.zig` (build via
   `zig build emit-tsir-attention-canary`) emits the attention CSL via
   `runtime/zig/src/tsir/emit_csl.zig:emitSemanticFunction`. New sim runner
   `bench/runners/csl-runners/attention_head256_f16kv_tsir_sim_runner.py`
   dispatches via `cs_python` against the cslc-compiled output. Bootstrap
   inputs (Q/K/V all-zero) produce sha256
   `5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef` --
   exact match to the Doppler probe at
   `bench/fixtures/tsir-real-doppler-transcripts/attention_head256_f16kv.doppler-transcript.json`.
   Same identity, different emit path. Three real cslc-rejection bugs
   fixed in `emit_csl.zig` (memcpy_params not forwarded; per-binding
   `@export_name` missing; layout-level params not forwarded to PE) and
   one in `emit_kernel_body_attention.zig` (`f32 = 1` rejected as
   comptime_int; switched to `{e}` formatter). 972/972 tests in
   `zig build test-wgsl`.

   head_dim=512 stays on hand-authored canary CSL: the TSIR-emit kernel's
   full `[kv_len * head_dim] = [15 * 512]` f32 K/V tensor (60 KB per PE
   for K + 60 KB for V) blows the WSE-3 single-PE 48 KB SRAM budget at
   width=1. Closing it needs either multi-PE distribution along the kv
   axis or a zero-input-elide mode in the attention emit body.

Cross-repo work (Doppler tree, separate from this commit set): the
frozen Doppler reference fixture data path landed
`src/inference/pipelines/text/tsir-fixture-writer.js` plus
`tools/run-program-bundle-reference.js --tsir-fixture-dir` so a Doppler
inference run captures activations at the four TSIR boundary points
(`post_rmsnorm`, `post_qkv`, `post_attn`, `post_ffn`) as `.npy` files.
A 31B node-surface partial run captured 3 of 4 boundary tensors at
L=0 before being killed (Gemma 4 31B has a chat-template / tokenizer
bug separate from the fixture path; user is debugging in another
thread). Doe-side `bench/tools/build_frozen_doppler_reference_manifest.py`
assembles the fixture into a frozen Doppler reference manifest the validator binds.

Open follow-ups:

- Doppler chat-template debug (cross-repo, gates re-running the fixture
  capture).
- Once 4-of-4 .npy files are captured at L=1, build the manifest and
  validate it; downstream attention-canary, single-block-parity,
  full-prefill, and multi-token continuation steps then bind.
- Attention-canary dispatch and full-prefill dispatch at manifest shape: gated on
  hardware execution since manifest-shape simfabric is wall-time
  prohibitive (each kernel invocation alone exceeds the 1800s
  chain_step_adapter timeout).
- Rung 9 manifest-shape multi-token orchestrator (the named
  `stateful_multi_token_runner_absent` blocker in
  `bench/out/r3-1-31b-bounded-multi-token-decode/receipt.json`).
- attention_head512_f16kv TSIR-CSL emit body: multi-PE distribution
  along the kv axis or zero-input-elide.

## 2026-04-25 — archived

The 2026-04-25 loop history (cycle 16 through `(late+2)`, including the
structured-compile-target slice) is archived at
[`archive/2026-04-25-late-and-cycles-16-21.md`](archive/2026-04-25-late-and-cycles-16-21.md).
Earlier cycles 7–15 + late+16–21 are at
[`archive/2026-04-25-loop-cycles-7-to-15.md`](archive/2026-04-25-loop-cycles-7-to-15.md);
the 2026-04-24 history is at [`archive/2026-04-24.md`](archive/2026-04-24.md).

## Current state

- The forward architecture for replacing classifier/template CSL lowering with
  parity-oracle-first TSIR lowering is documented in
  `docs/tsir-lowering-plan.md`. Phase A compiler surface is landed (schema,
  digests, frontend, planner, reference interpreter, and mechanical skeleton
  emitters for five backends including a TSIR-to-CSL skeleton; see
  [`docs/status/tsir.md`](./tsir.md)). The TSIR-to-CSL emitter has executable
  bodies for `fused_gemv`, `rms_norm`, `gather`, `residual_add`,
  `gelu_gated`, `kv_write`, and `kv_read`; the live CSL lane still routes
  through the classifier/template + `emit_csl_semantic_ops.zig` path for
  those kernels rather than through the TSIR emitter — the wiring switch is
  the open Item-2 work.
- The INT4 PLE CSL lane now applies manifest compile params to the live
  simulator plan and records the result at
  `hostPlanBundle.manifestCompileParamApplication`.
- The fresh simulator driver result on this host compiles **17 of 17**
  compile targets at manifest scale (embed, rmsnorm, rmsnorm_prefill,
  rmsnorm_decode, tiled, rope, attn_head256, residual, residual_prefill,
  residual_decode, gelu, gelu_prefill, gelu_decode, gemv, attn_decode,
  lm_head_gemv, sample). Source of truth:
  `bench/out/doppler-reference/gemma-3-1b-doe-csl-hostplan/trace.json.driver-result.json`.
- Runtime advances through `embed` (chunked dispatch, 6 sublaunches succeed
  in launch[0]) and `rmsnorm_prefill` (launch[1] succeeds end-to-end); was
  in `tiled` q_proj output memcpy_d2h when the 600s wallclock timeout hit.
  Source of truth:
  `bench/out/doppler-reference/gemma-3-1b-doe-csl-hostplan/simulator-evidence.json`.
- The blocker is no longer kernel architecture — the four kernels previously
  flagged (`embed`, `lm_head_gemv`, `attn_head256`, `attn_head512`)
  all compile cleanly and at least `embed` runs cleanly under the BF16
  layernorm-broadcast fix landed late+18 / cycle 7. Open work is now the
  simulator wallclock vs simfabric per-launch cost, the TSIR-to-live-path
  wiring, and the parity-comparison data the simulator-evidence gate
  cannot yet produce.

## Landed infrastructure

- Shared execution contract wiring between Doppler source artifacts, HostPlan,
  transcript receipts, and parity receipts.
- Manifest compile-param projection and apply path for the live transcript
  producer.
- HostPlan executor validator, execution-plan receipt, target-session probe,
  and bootstrap/runtime scaffolding.
- Fail-closed promotion gates for manifest compile params and transcript
  readiness.

## Ground truth

- SDK access is no longer the primary blocker on this host.
- `cslc` runs and produces real linker/compiler diagnostics.
- The missing work is bounded to kernel redesign plus the downstream transcript
  executor path that consumes those kernels.

## Use this shard for

- Cerebras SDK / CSL runtime status
- INT4 PLE compile/runtime blockers
- HostPlan executor status
- Simulator and hardware promotion status
