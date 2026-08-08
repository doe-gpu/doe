# Doe status: Cerebras CSL runtime bring-up

This is a live topical sub-shard split from `docs/status/cerebras-csl.md`.
Follow the shared shard policy in [`README.md`](../README.md); add entries here
only when they belong to the Gemma/Qwen CSL runtime bring-up subdomain.

## Lane status

This sub-shard does not restate verdicts or current launch index. Run the
status snapshot documented in [`../cerebras.md`](../../cerebras.md) and read
`bench/out/r3-cerebras-status/snapshot.md`. The snapshot is the only place that
holds current state for this lane; it reads receipts and the live Phase-7
`progress.jsonl` directly.

Dated bring-up entries below describe architecture and named blockers, not
"which launch are we on" or "what is the current verdict". Don't add those
back here — add them as new artifact-shaped fields and let the snapshot
surface them.

## 2026-05-02 — Prefill Q4K GEMV canonicalized through HostPlan, rope, and attention boundaries

The compact `<bos>sky color is` simfabric run exposed the remaining
canonicalization gap as a fail-closed launch-boundary error: L5 `rope` rejected
`activation:prefill:0002:layer0:q_proj` because the runner-substituted Q4K ->
f16 GEMV wrote the logical Q projection while the downstream HostPlan contract
still expected the old static `tiled_31b` layout. Launches through L4 were
checkpointed cleanly under
`bench/out/scratch/gemma4_31b_af16-checkpoint-bos-raw-sky-color-is-fast-embed512`.

Source now promotes that path into the explicit `prefill_q4k_gemv` contract.
Fresh Gemma 4 31B af16 HostPlan and simulator-plan bundles emit `tiled_31b`
with pattern `prefill_q4k_gemv`, Q4K byte weight metadata, f16 activation /
output metadata, and fused-GEMV compile source under the `tiled_31b` target
instead of a hidden SUMMA substitution. The runtime scheduler, execution-plan
materializer, sim runner, manifest compile-param projection, dtype contract,
schemas, and receipts now name the same pattern.

The shape bridge that the failed run needed is also explicit: logical Q/K/V
projection buffers stage into RoPE PE-head rows and tiled-attention query/KV
rows, then detile back to logical activation buffers for the following
projection. The fail-closed size check remains intact; the runtime now satisfies
it through declared transforms rather than bypassing it. Next action for the
active proof lane is to regenerate the HostPlan/session artifacts and resume
from the existing checkpoint toward `realSessionRuntime.status=output_ready`.
Because the canonicalization adds `compileTargets[].pattern` across the target
set and changes `tiled_31b` from static SUMMA metadata to explicit
`prefill_q4k_gemv`, the resume command must use the explicit
`--allow-checkpoint-canonicalization-drift` override together with the existing
runner-drift override when the runner hash changed. The override still requires
the same compile-target set and verifies every persisted buffer hash before
launching L5.

## 2026-05-02 — Cross-depth byte-identity restored after compile-root rematerialization

Gemma 4 31B and Qwen 3.6 27B cross-depth byte-identity are green again after
rematerializing the stale upstream compile roots. Gemma 1L-vs-61L is 2/2 pass
with 17 shared kernels matching; Qwen 1L-vs-64L is 2/2 pass with 15 shared
kernels matching.

Root cause was stale generated artifacts, not a numLayers-dependent emitter.
The stale `bench/out/r3-1-31b-manifest-fullgraph-compile-steps/compile/` root
was generated before emitter changes such as `sample/pe_program.csl` moving to
the bounded-smoke local-argmax form and `rope/pe_program.csl` gaining
multimodal-rope params. Regeneration policy: materialized compile roots under
`bench/out/*manifest-fullgraph-compile-steps/` must be regenerated after
emitter changes before byte-identity or dispatch evidence is restated.

The active `<bos>sky color is` L=1 simfabric transcript can now count toward
the 1-of-60-layer first-token parity step if it reaches generated-token/logits/lm-head/KV output readiness. Qwen
still remains separately fail-closed on the frozen reference manifest missing
the L=0 probes.

## 2026-05-01 — Layer C acceptance bar split: end-to-end load-bearing, per-kernel manifest-shape regression net

`docs/cerebras-model-ledgers.md` Layer C acceptance bar now separates the
load-bearing correctness items (end-to-end prefill + generated-token IDs
matching the frozen Doppler reference at L=1; per-step logits artifacts
comparing under the declared Doppler tolerance policy; manifest / HostPlan
/ CSL / reference-fixture hash chain unbroken) from the regression-net
artifact (all 23 manifest-shape kernels dispatched on simfabric,
bytes/digests recorded). The milestone queue also carries a one-paragraph
note that per-kernel/layout steps and composition/parity steps catch different bug classes and
neither subsumes the other.

The reframing is grounded in the Active fail-closed queue items 1-4 in
the same doc: lm-head dtype resolver, tied-dense lm-head routing,
missing prefill/decode tails in the smoke graph, and HostPlan accepting
`sample` without a logits producer. All four are composition /
phase-order / symbol-resolution bugs that per-kernel manifest-shape
dispatch passed through by construction (each probe runs one kernel in
isolation with its own inputs).

Operational consequence: per-kernel manifest-shape dispatch on
simfabric is no longer a hard prerequisite for the end-to-end Cerebras
correctness claim. It remains worth producing once and rerunning on
kernel change for regression coverage and for tightening the simfabric
wallclock calibration off the 8x3 canary proxy. The end-to-end
hardware receipt with exact generated-token parity, logits digest/tolerance
evidence, lm-head dispatch evidence, and KV-cache digests is what closes the
correctness ask.

## 2026-05-01 — Active end-to-end front: frozen Doppler sky prompt, decode step 1

Diagnostic smaller-target receipt now exists for one raw prefill token plus
one real decode step. `bench/tools/export_doppler_int4ple_reference.mjs`
emits schema-valid `producer.runtime=doppler_node_webgpu` receipts and the
reference-export schema now admits the Doppler KV byte-digest proof under
`kvCacheEvidence`. The generated diagnostic receipt is
`bench/out/doppler-reference/gemma-4-31b-af16-raw1-prefill-decode1/doppler_int4ple_reference_export.json`;
it uses `--no-chat-template`, prompt `The`, tokenized prompt `[818]`,
`decodeStepsRequested=2`, generated tokens `[236774, 236780]`, and
`kvCacheEvidence.status=output_ready`. This is a shrink-wrapped
prefill+decode diagnostic target; it does not supersede the frozen Doppler
sky acceptance target unless the active gate is deliberately retargeted.

The arithmetic probe split is explicit: raw `4**4=` is four prompt tokens
`[236812, 1018, 236812, 236784]`, but the Doppler greedy continuation repeats
the pattern (`[236812, 236784, 236812, 236784]`) rather than producing
`256`. The gated receipt is
`bench/out/doppler-reference/gemma-4-31b-af16-raw-4pow4-prefill-decode/doppler_int4ple_reference_export.json`.
The semantically useful arithmetic receipt is the chat-template run
`bench/out/doppler-reference/gemma-4-31b-af16-chat-4pow4-prefill-decode/doppler_int4ple_reference_export.json`;
it has 17 prompt tokens and generated tokens
`[236812, 1018, 236812, 578, 236743, 236778, 236810, 236825]`, rendering
`4**4 = 256`, with `kvCacheEvidence.status=output_ready`.

The preferred small non-chat diagnostic is now BOS plus compact raw sky text:
`<bos>sky color is`. It has four prompt tokens
`[2, 16012, 2258, 563]` and the two-step Doppler receipt
`bench/out/doppler-reference/gemma-4-31b-af16-bos-raw-sky-color-is-prefill-decode2/doppler_int4ple_reference_export.json`
generates `[3730, 236761]`, rendering ` blue.`, with
`kvCacheEvidence.status=output_ready`. This keeps the chat wrapper out
while preserving a sane model start token and a short, checkable answer.
The seven-token `<bos>The color of the sky is` receipt remains available at
`bench/out/doppler-reference/gemma-4-31b-af16-bos-raw-sky-prefill-decode2/doppler_int4ple_reference_export.json`.

Real 31B HostPlan session active front is now the small non-chat Doppler
parity target `<bos>sky color is`, using the Doppler receipt
`bench/out/doppler-reference/gemma-4-31b-af16-bos-raw-sky-color-is-prefill-decode2/doppler_int4ple_reference_export.json`
as the generated-token/logits/KV oracle and the simfabric session tree
`bench/out/r3-1-31b-af16-hostplan-session-bos-raw-sky-color-is`. The
frozen-sky session/checkpoint tree is preserved as historical acceptance
state, but the live simfabric lane moved to the compact BOS sky target to
reach complete prefill+decode transcript evidence first.

The earlier generic two-token launch-2 tiled_31b Q4K projection remains
plumbing evidence only. It proved that the full 512x512 SUMMA sim
dispatch can be swapped for a smaller real Q4K GEMV fabric dispatch with
f16 output through `chain_step_adapter.py --split-d2h-rows`, reusable
tile output validation, and missing row/output tile replay. It is not
the acceptance target by itself.

The chunked-export D2H row-split pattern is established for the
rms_norm f16 output as 21 D2H-addressable chunks in
`runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_rmsnorm_pack.zig`. A simpler
single-buffer f16 pack landed for the TSIR emit lane in the new
`runtime/zig/src/compiler/tsir/emit_csl_f16_pack.zig` and is wired into
`runtime/zig/src/compiler/tsir/emit_kernel_body.zig::emitCslRmsNorm`. For the
tiled_31b Q4K projection, the current compact path is a taller f16
row-split copyback from the GEMV sink column. Compile probes under
`bench/out/scratch/q4k-height12-probe/` and
`bench/out/scratch/q4k-height48-probe/` validate taller output-PE-row
shapes with the same per-PE memory footprint, but the active simfabric
resume stays on the runtime-proven height-4 row-split path because the
height-48 runtime probe did not advance past its first D2H row. Sharded
batch adapters are recorded in the batch manifest, but this simfabric host stalls
concurrent Q4K shards at `SdkRuntime.run()`, so the active compact run keeps
one Q4K shard with durable partial reuse. The Q4K shard count remains
explicit as `--session-prefill-q4k-gemv-jobs` so embed ROI and lm-head
tile parallelism stay separate from this simulator D2H envelope.
The session runner now also exposes
`--session-embed-roi-hidden-per-pe` for clean retries of the embed ROI
launch; it is guarded by a per-PE buffer budget check and records the
override in the embed ROI spec instead of changing the chunking silently.
Checkpoint resume now has an explicit
`--allow-checkpoint-runner-drift` mode for orchestration-only runner
edits; it still validates manifest/config/compile-target identity and
all persisted buffer hashes before loading completed launches.

Checkpoint storage decoupled from runtime working buffers in
`bench/runners/csl-runners/int4ple_checkpoint.py`: the hardlink path
is replaced with always-copy so per-row D2H rewrites cannot
retroactively mutate earlier checkpoint bytes. Pinned by
`bench/tests/test_int4ple_checkpoint.py::test_source_buffer_rewrite_does_not_mutate_checkpoint`.
The frozen-sky embed ROI adapter now also writes spec-hash-bound partial
checkpoints after each sublaunch, so launch 0 can resume before the
full activation buffer is assembled. Q4K tile reuse validation, Q4K
shard planning, and embed ROI partial checkpoint round-trips are pinned
by focused tests in
`bench/tests/test_int4ple_hostplan_runtime_timeout.py`.

## 2026-05-01 — real-session transcript evidence becomes the bounded-smoke gate path

The inference evidence gate now treats a complete
`realSessionRuntime.status=output_ready` transcript as the authoritative
token-output evidence path for bounded Gemma 4 31B af16 prefill/decode. A
complete transcript must match the requested decode count, carry generated
token IDs, per-step logits digests, lm-head dispatch records, and
runtime-captured KV-cache digests.
Incomplete or malformed `output_ready` transcripts fail closed instead of
falling back to per-kernel evidence.

The HostPlan streaming front door and bounded-smoke receipt builder now pass
real-session transcript evidence into the gate. Once the resumable simfabric
session reaches `output_ready`, stale or incomplete manifest-shape per-kernel
lm-head evidence no longer blocks the end-to-end prefill/decode receipt. Until
that transcript exists, current checkpoint-stopped and not-executed traces
remain blocked by explicit runtime/transcript blockers.

## 2026-04-30 — session-tiled lm-head becomes the active simfabric path

The canonical real-prompt session now has a one-decode root with a `hostplan_session_checkpoint_prefix_reuse_receipt` proving the reused prefix.
It resumed through real `ple_embed` launch 16 and validated explicit
`--session-embed-roi-jobs` groups with serialized checkpoint writes.

The active simfabric strategy moved from per-kernel lm-head aggregate-first to making lm-head tiling part of the real HostPlan session. Existing partial-only per-kernel workers were stopped after durable tile receipts; they did not touch `lm_head_prefill.json` or `summary.json`.

The HostPlan executor now exposes explicit `dense_gemv_width_tiled_session` mode: a session `lm_head_prefill` launch is intercepted after real activation and weight staging, dispatched through dense-GEMV width-row tiles, host-reduced into the session logits buffer, and presented to the next session launch. Launch receipts can carry `inputBuffers` for receipt-local input->output edges; tile partial receipts can carry `receiptIdentity` with `sessionStepId`, `sessionStateSha256`, `inputActivationSha256`, launch index, and target name; transcripts preserve lm-head `dispatchMode`, `sessionTileIdentity`, and tile coverage beside logits digests.

This is source and harness infrastructure only until a real prompted session run reaches `output_ready`. The bounded-smoke receipt remains blocked on `dispatch_evidence_lm_head_unbound`; sample remains bound.

## 2026-04-30 — lm-head D2H envelope and width-row tiling

The generic chain-step adapter now emits `phase:*` breadcrumbs around SDK load/run, H2D, launch, D2H, and stop. For Gemma `lm_head_prefill`, those breadcrumbs show the full `width=160,height=512` manifest target and smaller `height>1` row blocks reach `launch_complete` and then stall in SDK D2H with zero output bytes.

The real simfabric envelope found on this host is `height=1` with hidden-width tiles below the failing full width: `width=120,height=1` writes a real `partial.npy`, while `width=128,height=1` and full `width=160,height=1` stall at D2H. The manifest runner now keeps lm-head evidence classes contract-visible: `monolithic_full_fabric`, `dense_gemv_width_tiled`, `dense_gemv_row_tiled`, and future `resident_weight_session` evidence do not share a silent gate path. Routine refresh keeps the monolithic path unless a tile mode is explicitly requested. Tiled receipts carry phase events, tile-shape D2H safety metadata, coverage, compile identity, weight input scope, and host-reduction metadata. The tiled planner clamps hidden-width chunks under the current simfabric element-count guard and only probes unsafe shapes through explicit diagnostic sweep mode.
Width-row tiling can now resume only from verified tile partial receipts that match the tile command, input hashes, compile identity, output hash, and shape-safety metadata; bare partial files still do not count. Coverage separates receipts on disk from verified reusable, fresh-emitter, and accepted partials; stale receipt files cannot inflate progress.

The SDK wrapper now defaults Singularity/Apptainer temp and cache paths to `bench/out/scratch/csl-container/` so SIF extraction does not consume tmpfs space. Failed tmpfs rootfs extraction sandboxes were cleared before the next lm-head evidence attempt.

The full `lm_head_prefill` governed receipt is still not bound. The official summary now records `dispatchMode=dense_gemv_width_tiled`, `blocker=dense_gemv_width_tile_dispatch_budget_exhausted`, `tileD2HMode=single_region_copyback`, `maxRowTileHeight=1`, and verified height-1 SDK partials; `sample` was refreshed against the regenerated HostPlan hash and remains bound.

Diagnostic height-16 split-D2H tiles now carry durable `phase-trace.log` breadcrumbs and still stall at `memcpy_d2h_start`; the dense-GEMV emitter now passes `pe_y`, gates command stream completion to row 0, and assigns row-specific reduction colors, but multi-row dense-GEMV tiles are not claim-eligible until a receipt proves D2H copyback completes.

Focused coverage lives in `bench/tests/test_manifest_kernel_probe_runner.py` and `bench/tests/test_int4ple_hostplan_runtime_timeout.py`. Follow-up: split `manifest_kernel_probe_runner.py` materialization/receipt helpers and shard `manifest_dense_gemv_tiles.py`; both exceed the Python tooling cap.

## 2026-04-30 — f16 dtype gate v2 and checkpoint 81 evidence

`config/doe-csl-dtype-contracts.json` schema version 2 requires Gemma
`q4k-ehf16-af16` and Qwen `q4k-eaf16` f16 CSL contracts to declare activation,
KV, output, lm-head/logits/sample, accumulation, and kernel-class dtype
surfaces, including Qwen q/k norm, causal prefill, gated FFN, convolution,
linear-attention/DeltaNet, SSM, and recurrence-carry obligations.

The Gemma and Qwen af16 per-kernel summaries were refreshed without inventing
evidence. Sample is bound for both models. Gemma `lm_head_prefill` now
uses the dense-GEMV sink-column D2H region contract in per-kernel and session
launch adapters, but the full manifest compile still times out before writing
output bytes. A row-shard lm-head compile/run proves the smaller fabric path
can produce real output; full token-output evidence now needs compile-time
lm-head tiling plus aggregate tile receipts. Qwen remains blocked too.

`bench/out/r3-1-31b-af16-bounded-inference-smoke/receipt.json` validates the
v2 `cslDtypeContract`; its only dispatch gate reason is
`dispatch_evidence_lm_head_unbound`, with session and transcript blockers
still present.

The real Gemma HostPlan checkpoint resume advanced to `bench/out/scratch/gemma4_31b_af16_hostplan_streaming.f16-e2e-plefix.ckpt81.json`.
That scratch trace is `checkpoint_stopped`; it is not transcript evidence and
does not bind the final_norm -> lm_head -> sample path.

`bench/out/r3-cross-model-parity/receipt.json` was refreshed with Gemma/Qwen af16 lanes required; it remains `unbound` on Gemma budget and Qwen hash-spine blockers.

Gemma AF16 bounded-smoke synthesis and phase-6 cross-model parity aggregate are now ready to re-run; the `dispatch_evidence_lm_head_unbound` blocker should clear when the new `lm_head` cell's bound dispatch verdict appears as `verdict=bound` in the per-kernel summary.

## 2026-04-30 — Doe/Cerebras af16 contract and PLE SUMMA routing land

Doe now has an explicit Cerebras CSL dtype contract registry at
`config/doe-csl-dtype-contracts.json`, validated by
`config/doe-csl-dtype-contracts.schema.json` and wired through
`config/schema-targets.json`. The Gemma `q4k-ehf16-af16` and Qwen
`q4k-eaf16` contracts declare `hostPlanActivationDtype=f16`,
`fallbackPolicy=forbid_implicit_af32`, f16 activation/KV/output transport,
f32 logits/sample comparison where the kernels require it, and
weightsRef identity preservation for shared Q4K packs.

The Gemma af16 streaming trace and bounded-smoke receipt builder now carry
`cslDtypeContract` next to the Doppler `dtypeProfile`; existing unpromoted
bounded evidence cannot promote until the current per-kernel gate binds
lm-head dispatch. The checked-in bounded receipt remains blocked by the
inference evidence gate, not promoted by the contract metadata.

Runtime staging now accepts f16 SUMMA A/B tiling and f16 constant state without
silently widening to af32. The Zig HostPlan tool routes af16 compile-target
metadata to f16 bindings and moved binding metadata into
`runtime/zig/src/spatial/csl/csl_host_plan_bindings.zig` so
`runtime/zig/src/spatial/csl/csl_host_plan_tool.zig` stays under the Zig source line cap.

Real-session PLE routing now records each layer's own PLE gather, projection,
and norm buffers instead of chaining layer outputs across the PLE batch. The
fresh checkpoint probe under the patched runner at
`bench/out/scratch/gemma4_31b_af16-checkpoint-f16-e2e-plefix` has persisted
real `ple_proj` launch receipts for layers 0 through 3, with the latest trace
at
`bench/out/scratch/gemma4_31b_af16_hostplan_streaming.f16-e2e-plefix.ckpt64.json`.
The layer 0 and layer 1 traces are
`bench/out/scratch/gemma4_31b_af16_hostplan_streaming.f16-e2e-plefix.ckpt61.json`
and
`bench/out/scratch/gemma4_31b_af16_hostplan_streaming.f16-e2e-plefix.ckpt62.json`.
That clears the previous `transform_field_missing:sourceCols` blocker for the
first PLE SUMMA projection handoff. The run remains checkpoint-stopped before
token/logit/KV transcript completion. The manifest-shape per-kernel summary
now preserves the bound sample receipt and the blocked lm-head receipt; until
lm-head binds, bounded-smoke evidence remains fail-closed.

Tracked sharding follow-up: Owner Doe Cerebras runner. Next split targets are
to move HostPlan execution-plan materialization out of
`bench/runners/csl-runners/int4ple_hostplan_execution_plan.py`, to move the
HostPlan runtime subprocess/checkpoint launch loop out of
`bench/runners/csl-runners/int4ple_compile_target_sim_runner.py`, to move the
Gemma af16 session scheduler helpers out of
`bench/runners/csl-runners/gemma4_31b_af16_session_runtime.py`, and to move
the Gemma af16 front-door trace assembly out of
`bench/runners/csl-runners/gemma4_31b_af16_hostplan_streaming_runner.py`.

## 2026-04-30 — HostPlan launch-step D2H stalls now fail closed

Checkpoint resume reached the next HostPlan launch and entered the
`launch_step_memcpy_d2h` phase for the resumed output copyback. D2H here means
device-to-host: SDK runtime memory is being copied back into a host CPU buffer.
That scratch resume was interrupted and remains non-promoted evidence.

`int4ple_compile_target_sim_runner.py` now applies
`--launch-timeout-seconds` to the HostPlan launch-step subprocess path. A
timeout writes an `int4ple_launch_step_receipt` with
`blockers=["launch_step_timeout"]`, records `hostplan_launch_timeout` in the
progress log, and returns a typed runtime blocker instead of leaving the
front-door runner parked in the copyback path. The Gemma 4 31B af16 streaming
front door exposes the same flag through the real-session runtime. The default
launch-step bound is raised for resumed D2H copyback attempts, while `0`
continues to disable the bound for an explicitly unbounded run.

This is a fail-closed execution taxonomy improvement only. It does not bind
the current lm-head/sample per-kernel evidence, and it does not promote the
scratch checkpoint-resume attempt to token/logit/KV transcript evidence.

Tracked sharding follow-up: Owner Doe Cerebras runner. Next split targets are
to move the HostPlan runtime subprocess/checkpoint launch loop out of
`bench/runners/csl-runners/int4ple_compile_target_sim_runner.py`, and to move
the Gemma af16 weight-key resolution helpers out of
`bench/runners/csl-runners/gemma4_31b_af16_session_runtime.py`.

## 2026-04-30 — Gemma 4 31B af16 bounded-smoke blocker taxonomy follows session runtime

The bounded-smoke synthesizer now carries `realSessionRuntime` through the
HostPlan streaming trace summary and reports
`real_session_runtime_not_output_ready` when the session-runtime contract is
present but has not produced a token/logit/KV transcript. The legacy
`combined_session_runtime_absent` blocker remains only for older traces that
do not carry a real-session block.

Focused coverage now expects the current per-kernel evidence gate to report
`dispatch_evidence_lm_head_unbound` for the checked-in af16 target inventory:
the lm-head target is present, but no lm-head dispatch receipt is bound. A
current dry runner trace reaches `realSessionRuntime.status=ready_not_executed`
with scheduler bound, executor validator passed, execution plan planned, and
sample feedback bound; the remaining local blockers are per-kernel evidence and
the explicit lack of SDK execution.

A bounded `--execute --stop-after-launch 0` checkpoint run now reports
`realSessionRuntime.status=checkpoint_stopped`, with SDK bootstrap ready for
tensor movement and runtime status `stopped_at_checkpoint`. The top-level trace
still remains blocked because per-kernel evidence is not bound and the run
intentionally stops before transcript completion.

## 2026-04-29 — Gemma 4 31B af16 token-output contract gate lands

The Gemma 4 31B execution-v1 smoke graph now carries explicit
`final_norm -> lm_head -> sample` tails for both prefill-generated and
decode-generated tokens. The lm-head route no longer treats tied F16
`embed_tokens.weight` as a Q4K `lm_head.weight`; the runner-side resolver
accepts tied dense F16/BF16/F32 embeddings only for the dense lm-head path and
rejects Q4K lm-head selection unless an explicit Q4K `lm_head.weight` exists.

HostPlan lowering now allows `sample` in prefill or decode only after an
immediately preceding same-phase logits producer, and rejects compute after a
same-phase sample. The tied dense route uses the full-vocabulary
`lm_head_prefill` SUMMA compile target; the generated target for the
31B smoke graph covers the vocabulary with one-row logits tiles.

Focused coverage now includes sample-without-logits, explicit prefill/decode
logits tails, compute-after-sample rejection, invalid tied-F16-vs-Q4K lm-head
selection, and prefill/decode dispatch expansion. `zig build test-wgsl`,
`zig build csl-host-plan-tool`, and the focused Python runner/receipt tests
pass locally.

The remaining open gate is runtime/evidence: stage real weights, bind host
I/O, run the serial HostPlan with KV state and sample feedback, then
regenerate HostPlan-derived receipts. Older pre-logits HostPlan families stay
superseded for token-output inference claims.

## 2026-04-29 — Gemma 4 31B af16 token-output evidence is fail-closed

The Gemma 4 31B af16 HostPlan family that ends at `sample` without an explicit
logits producer is superseded for inference claims. Receipts derived from that
inventory remain compile/front-door evidence for the emitted targets, but they
are not token-output prefill/decode evidence.

The active queue is now contract-first:

- add a manifest-driven lm-head resolver that distinguishes real Q4K
  `lm_head.weight` from tied F16 `embed_tokens.weight`;
- add the F16 dense tied-lm-head path and padded embedding handling before
  using tied embeddings for logits;
- make post-prefill and post-decode final-norm / lm-head / sample paths
  explicit in execution-v1 and HostPlan lowering;
- require every `sample` launch to consume a typed compatible logits producer,
  with dtype, shape, and layout checked before receipts bind;
- extend the real session runtime to stage weights, bind host I/O, launch the
  serial HostPlan, carry KV cache, feed sampled tokens forward, and emit
  transcript logits/tokens;
- regenerate downstream HostPlan, compile, per-kernel, streaming, and bounded
  inference artifacts after the contract lands.

The corresponding queue and invariants are tracked in
`docs/cerebras-model-ledgers.md`. This is not a runner paper-over: the upstream
graph-to-HostPlan inventory and sample-logits contracts must fail closed before
any generated-token evidence can be promoted.

## 2026-04-29 — CSL emulator covers remaining 31B compile-target semantics

`bench/tools/run_csl_webgpu_emulator.mjs` now recognizes every compile target
in the current Gemma 4 31B af16 CSL bundle: tiled SUMMA matmul, RoPE, tiled
prefill attention, decode attention, Q4K fused GEMV, KV cache write, and
sample. The CPU semantic backend executes each family against raw fixture H2D
buffers, including PE-local flash-attention state for `compute`/`finalize` and
Q4K byte dequantization for fused GEMV. Result receipts now expose hashes for
source-defined internal state under `execution.state`. The WebGPU backend has
matching generated WGSL for the same families and creates hidden GPU buffers
for source-defined attention state when explicit `--backend webgpu` execution
is available.

The real 31B bundle still blocks at H2D fixture binding when no Doppler/RDRR or
raw fixtures are supplied; this is an input-materialization blocker, not an
unsupported CSL semantic in the source inspector.

## 2026-04-29 — Gemma 4 31B af16 session runner sharding follow-up

`bench/runners/csl-runners/gemma4_31b_af16_hostplan_streaming_runner.py`
now carries the CLI front door, weightsRef staging, dispatch expansion,
real-session scheduler, runtime-config materialization, host I/O layout
emission, and trace assembly. This exceeds the Python benchmark-tooling shard
threshold.

Owner: Doe Cerebras runner. Next split target:
`bench/runners/csl-runners/gemma4_31b_af16_session_runtime.py` should own the
real-session scheduler, weight mappings, host I/O layout, runtime-config
writing, serial launch binding, KV schedule, and sample feedback assembly.
The existing streaming runner should keep CLI parsing, refresh orchestration,
and final trace aggregation.

## 2026-04-29 — CSL emulator records D2H artifacts and simple element-wise bodies

`bench/tools/run_csl_webgpu_emulator.mjs` now accepts `--d2h-out-dir` and writes
each `memcpy_d2h` payload as a byte artifact, with the file path, byte length,
and sha256 recorded on the operation receipt. This gives emulator parity checks
a concrete file surface instead of forcing every consumer to trust only the
inline hash.

The source inspector also recognizes the simple DOE-emitted `element_wise`
identity body used by the current 31B `ple_residual` target:
`output[idx] = input[idx] * 1.0`. The semantic runs on both CPU and generated
WGSL/WebGPU backends under the explicit `elementwise_identity` label.

## 2026-04-29 — E2B attention-core receipt drift fixed

`bench/tools/run_gemma4_e2b_manifest_shape_attention_core.py` now invokes the
shape runner with absolute repo paths when running through the SDK Python
wrapper. This prevents the container scratch CWD from turning
`bench/runners/csl-runners/gemma4_e2b_manifest_attention_core.py` into a
nonexistent scratch-relative path. Blocked shape-run fallbacks also carry the
schema-required shape fields and `executedRun.numericalParity.comparison`, so a
real SDK failure remains a valid blocked receipt instead of corrupting the
schema gate.

The E2B manifest-shape attention-core receipt, Doppler capture-to-CSL lowering
receipt, and E2B model runtime receipt were regenerated from the fixed path.
The model receipt now links the current attention-core and lowering artifact
hashes, and `bench/tools/validate_e2b_receipt_links.py` passes.

## 2026-04-29 — Restricted CSL WebGPU emulator runner lands

`bench/tools/run_csl_webgpu_emulator.mjs` now consumes
`csl_webgpu_emulator_input` artifacts and emits
`config/csl-webgpu-emulator-result.schema.json` receipts. The runner models the
ordered host operation graph, binds raw fixture H2D files by device symbol,
tracks per-symbol hashes, and executes supported launches on either the CPU
semantic backend or the Doe Node WebGPU backend when requested and available.

The supported CSL source subset is explicit: `gather`, `residual_add`, `gelu`,
`rms_norm`, and no-op `sys_mod.unblock_cmd_stream()` launches. Missing fixtures,
unsupported operation kinds, unsupported CSL source, and unimplemented
Doppler/RDRR materialization all produce blocked receipts with typed blockers;
the runner does not fabricate tensor inputs or promote a receipt to simulator or
hardware parity.

## 2026-04-29 — CSL WebGPU emulator input contract lands

`config/csl-webgpu-emulator-input.schema.json` now defines the source-preserving
input bundle for a future CSL-source-to-WebGPU semantic emulator. The contract
binds the existing HostPlan bundle surface (`host-plan.json`,
`runtime-config.json`, `simulator-plan.json`), per-target `layout.csl` and
`pe_program.csl` source hashes, the synthesized `csl_operation_graph`, and
optional Doppler Program Bundle / RDRR manifest / reference transcript identity.

`bench/tools/build_csl_webgpu_emulator_input.py` builds that artifact from an
existing CSL bundle plus driver result. The status is explicitly
`input_contract_only_not_execution`: no WebGPU execution, CSL simfabric parity,
or hardware claim is created by this artifact. It gives the upcoming emulator
a normalized source contract instead of requiring it to infer layout, launches,
copy regions, and source hashes from scattered files.

## 2026-04-29 — Gemma 4 31B af16 bounded inference smoke contract

`bench/tools/synthesize_gemma4_31b_af16_bounded_inference_smoke_receipt.py`
now emits the Gemma 4 31B af16 bounded simulator-smoke receipt at
`bench/out/r3-1-31b-af16-bounded-inference-smoke/receipt.json`.

The receipt is schema-validated by
`config/doe-gemma4-31b-af16-bounded-inference-smoke.schema.json` and
hash-links the af16 Doppler manifest, the af16 frozen Doppler fixture, the
af16 HostPlan compile receipt, and the current manifest-shape per-kernel
summary. It records the caller-selected prefill/decode budget and the exact
blocked taxonomy instead of inventing a CSL token sequence. The source-side
blockers for incomplete weight-symbol mapping and stale dry-run per-kernel
summaries are now cleared in the runner trace; the receipt carries the
remaining host/runtime blockers from the streaming trace.

`bench/runners/csl-runners/gemma4_31b_af16_hostplan_streaming_runner.py`
now owns the Gemma 4 31B af16 real-inference front door: it resolves
`weightsRef` to the primary weight pack, checks shard presence, resolves all
execution-v1 weight symbols, expands the prefill/decode schedule, and exposes
the af16 per-kernel refresh command. The trace records all 31B af16 shards as
present and every required weight key as resolved, with explicit policy
records for architecture-disabled PLE projection-norm inputs and 31B
linear-attention layers that intentionally lack `v_proj`. The current
per-kernel summary is dry-run-only; when a refresh is requested and the SDK
container cannot launch, the bounded receipt reports the SDK preflight
failure rather than treating the stale dry-run summary as the active source
blocker. The remaining runtime blocker is the combined session executor that
binds cross-kernel tensors and KV cache state and emits the token/logit/KV
transcript.

`bench/runners/csl-runners/manifest_kernel_probe_runner.py` now supports
source-preserving refresh controls for future reruns: `--jobs` runs
independent kernel probes in parallel, `--resume` reuses existing non-dry-run
dispatch receipts with the current HostPlan hash when they are already bound
or reached the timeout taxonomy, and
`--schedule heavy-first` orders targets by metadata-estimated manifest-shape
I/O size so large kernels can start before smaller probes. The Gemma af16
front door passes those controls through via `--refresh-jobs`,
`--refresh-resume`, `--refresh-schedule`, and
`--refresh-timeout-seconds`. `--cmaddr` remains the explicit real-fabric path;
custom `--host-plan`, `--compile-root`, and `--refresh-out-dir` remain the way
to run a shape-reduced debug lane without mixing it with the manifest-shape
claim receipts.

The first SDK-capable refresh exposed source-side probe issues that are now
fixed in the runner path. `bench/runners/csl-runners/chain_step_adapter.py`
packs logical `f16` tensors through 32-bit memcpy words because this SDK rejects
16-bit memcpy calls. `rope` / `rope_partial` are in-place kernels, so the shared
in-place classifier treats `input` as the output symbol for those kernels;
the predictor, layout receipt, and probe runner now agree on the same d2h
contract. The summary entries now carry `dispatchTimedOut` so timeout taxonomy
is visible without opening each per-kernel receipt. Existing refreshed receipts
under `bench/out/r3-1-31b-af16-manifest-simfabric-per-kernel/` predate those
fixes; rerun the refresh command on the SDK-capable host to replace the
dispatch-exit blockers with current evidence.
