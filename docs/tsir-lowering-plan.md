# TSIR lowering plan

## Purpose

The goal is one program and many faithful realizations. Doppler already treats
WGSL as the source program and WebGPU as one realization of that program.
Doe's job is to extend that discipline across backends without turning each new
backend into a separate hand-authored runtime.

The current CSL path does not meet that bar. It has one real direct-lowering
success case in matmul, but the broader non-GEMM path still depends on
classifier-selected template emitters. Those emitters rediscover placement,
residency, collectives, and numerical behavior locally. That is why the current
CSL blockers look like hardware fit failures when the deeper problem is
compiler structure.

This document defines the forward architecture for fixing that: a Tiled Spatial
IR (TSIR) between WGSL IR and backend emitters, with a parity oracle defined
before backend-specific lowering decisions.

This is a plan document, not a landed-claim document. Current code still uses
the classifier/template path for CSL. The in-tree `runtime/zig/src/compiler/tsir/`
surface is scaffolding for this plan, not a completed pipeline.

Status note, 2026-04-25: the older "WS4 memory blockers choose the first real
kernels" framing is partly stale. After the current HostPlan and BF16
broadcast fixes, `embed`, `lm_head_gemv`, `attn_head256`, and
`attn_head512` compile at Gemma 3 1B scale. The active simfabric blocker is the
tiled SUMMA `launchIndex=2` host D2H stall tracked in
`docs/cerebras-model-ledgers.md`. Bounded residency remains important for 31B and
for TSIR correctness, but it is no longer the immediate 3 1B execution proof
blocker.

## What TSIR means

TSIR means **Tiled Spatial IR**.

Each word matters:

- **Tiled**
  - TSIR represents loop nests, iteration axes, and tile factors explicitly.
  - Tensor work is expressed as bounded tiles and declared reduction regions,
    not as "one PE materializes the full logical buffer" unless that is an
    explicit legal residency choice.
  - This is what lets the compiler reason about fit, streaming, recompute, and
    collective boundaries instead of inheriting those choices from a template.

- **Spatial**
  - TSIR makes placement on a PE fabric first-class.
  - It represents PE-grid topology, residency class per buffer, collective
    nodes, reduction-tree shape, and the target descriptor that says what the
    hardware can actually do.
  - That matters for Cerebras WSE-3 because placement, routing, and per-PE
    memory are part of the execution contract, not backend-private details the
    emitter can guess differently per kernel.

- **IR**
  - TSIR is a schema-backed, hashable compiler contract.
  - It splits stable source meaning from target-specific realization:
    - `tsir.semantic`
    - `tsir.realization`
  - Those structures produce distinct digests so manifests, receipts, and
    replay can pin the exact lowering unit, not only the original WGSL.

In short:

```text
WGSL -> TSIR -> mechanical backend emitters
```

instead of:

```text
WGSL -> classify -> per-kernel template logic
```

For Cerebras, the backend emitter is CSL plus the surrounding runtime-facing
artifacts. For WebGPU-shaped lanes, TSIR can drive a validated WebGPU lowering
surface such as WGSL re-emission or an equivalent backend-facing realization.
The key point is the same in both cases: backend codegen becomes mechanical
with respect to an explicit lowering contract.

## Surrounding context

TSIR is not a replacement for Doppler's program bundle and it is not a
replacement for Doe IR.

The surrounding boundary is:

1. **Doppler owns the source program contract**
   - manifest identity
   - execution graph
   - WGSL modules and digests
   - weights and runtime profile
   - reference transcript

2. **Doe's existing WGSL frontend owns semantic recovery**
   - lexer
   - parser
   - sema
   - Doe IR

3. **TSIR is the lowering contract after WGSL IR and before backend emission**
   - it is where tiling, residency, collectives, and exactness become explicit
   - it is where rejection becomes typed and replayable

4. **Backend-specific artifacts consume TSIR**
   - CSL emitter and HostPlan-facing artifacts for Cerebras
   - WebGPU/backend lowering artifacts for WebGPU-shaped lanes

5. **Parity compares each backend against the oracle defined over TSIR**
   - never backend-versus-backend only

For the CSL lane, this means HostPlan stays important, but it moves to the
right place in the stack. HostPlan is the runtime orchestration contract for
launches, tensors, and receipts. It should not also be the place where kernel
meaning, residency strategy, or numerical semantics are rediscovered. TSIR sits
before HostPlan and makes those decisions explicit once.

For the Doppler/RDRR lane, this means lowering becomes part of artifact
identity. The manifest still owns source identity. TSIR adds lowering identity:
what semantic kernel was lowered, what realization was chosen, what target
descriptor it was lowered for, and what exactness class or rejection reason
applies.

## Why TSIR is needed

TSIR is needed because the current classifier/template path does not scale as a
proof-bearing compiler boundary.

Today, each non-GEMM CSL emitter tends to rediscover its own answers to
questions that should have one compiler-level answer:

- what part of the loop nest belongs on each PE
- whether a buffer is replicated, sliced, streamed, or recomputed
- what the reduction or collective structure really is
- what numerical order is declared versus accidental
- when to reject because the kernel cannot fit or cannot lower faithfully

That local rediscovery causes three concrete problems.

First, **fit failures look like hardware facts when they are often emitter
facts**. If a template allocates `[num_tokens * hidden_size]` per PE, the
result looks like "Cerebras cannot run this kernel." The more accurate
statement is "this emitter materialized the wrong thing locally." TSIR is the
place where the compiler chooses a bounded residency strategy before emission.

Second, **auditability collapses**. A per-kernel template can be locally
correct and still impossible to compare across kernels because each one carries
different hidden placement assumptions. A schema-backed TSIR makes those
choices explicit and hashable.

Third, **parity has no stable lowering unit**. Without TSIR, the manifest pins
the source program but not the compiler's realization of that program on a
spatial backend. That makes replay weaker than it should be, because a
compiler-policy change can silently alter the lowered kernel without changing
the source program identity.

TSIR fixes these three problems by moving the load-bearing decisions into a
shared compiler layer:

- the frontend recovers structure once
- the planner chooses residency and collectives once
- the emitter stops making semantic decisions
- the parity oracle judges the declared lowering, not template accidents

## Current scaffold already in tree

Phase A compiler surface has landed for the bootstrap catalog
(`fused_gemv`, `rms_norm`, `gather`). For live TSIR status refer to
[`docs/status/tsir.md`](status/tsir.md); the plan doc gives the shape
of what exists, not counts or dates. Archive of 2026-04-23 TSIR Step 4
incremental history lives in the tail of
[`docs/status/archive/2026-04-02-to-2026-04-15.md`](status/archive/2026-04-02-to-2026-04-15.md).
Deep 2026-04-24 TSIR Step 7-12 entries live in
[`docs/status/archive/2026-04-24-tsir.md`](status/archive/2026-04-24-tsir.md).

TSIR core under `runtime/zig/src/compiler/tsir/`:

- `schema.zig` — two-level TSIR shape (`Semantic`, `Realization`), exactness
  classes aligned to RDRR, rejection taxonomy, and `SemanticBody` contract
  (body ops for `fused_gemv` / `rms_norm` / `gather`, RMSNorm epsilon source
  + binding/offset plumbing).
- `digest.zig` — canonical serialization and SHA-256 digests for semantic,
  realization, and emitter-code identity.
- `family_hint.zig` — structural classifier that infers coarse family hints
  from IR shape; hints are tiebreakers only, never change feasibility or
  rejection.
- `frontend.zig` — WGSL IR to TSIR semantic lowering for bindings, axes,
  reductions, collectives, typed rejections, family hints, and
  kernel-specific semantic body recovery (fused_gemv, rms_norm, gather).
- `planner.zig` — correctness-first TSIR realization planning for
  residency, tile factors, PE grid, reduction tree choices,
  descriptor-checked collectives, target hashes, and typed rejections.
- `collective_synthesis.zig` — dedicated Step 6 pass for descriptor-backed
  collective lowering: native-capability + exactness checks, fabric-color
  assignment under the descriptor's budget, and typed rejections when a
  target cannot host the declared collective. Consumed by the planner.
- `reference_interpreter.zig` — scalar reference oracle covering the three
  bootstrap families across `{f32, f16, bf16}` with `strict_ordered` and
  `associative_allowed` reductions plus RMSNorm `literal_f32` and
  `uniform_field` epsilon. Unsupported shapes fail closed with
  `NotImplemented`.
- `emit_kernel_body.zig` — shared semantic-aware executable body writer
  for the Phase A bootstrap families (`fused_gemv`, `rms_norm`,
  `gather`) across WebGPU, CSL, MSL, DXIL/HLSL, and SPIR-V/GLSL text
  surfaces.
- `emit_csl.zig` — TSIR-to-CSL emitter. Realization-only entry points
  still serialize contract skeletons; semantic-aware entry points emit
  executable bootstrap family bodies.
- `emit_webgpu.zig` — TSIR-to-WebGPU emitter. Realization-only entry
  points still serialize contract skeletons; semantic-aware entry points
  emit executable WGSL bootstrap family bodies.
- `emit_msl.zig` / `emit_dxil.zig` / `emit_spir_v.zig` — portable backend
  emitters consuming a shared text skeleton helper plus shared executable
  body writer.
- `emit_text_skeleton.zig` — shared contract-text serialization helpers
  used by the five backend skeleton emitters.
- `mod.zig` — public module surface.

Each of the five backend emitters exposes an `emitterCodeDigest()` that
SHA-256s its own source text plus shared emitter-helper source. Pairwise
distinctness across all five is locked by test so
manifest-lowering entries cannot silently ambiguate which backend
produced an artifact.

Target descriptors under `runtime/zig/src/compiler/targets/`:

- `webgpu_generic.zig` and `wse3.zig` — conservative portable WebGPU
  profile and Cerebras WSE-3 profile. Descriptor fields split into
  `correctness` (hashed, participates in realization identity) and
  `planner` (search-quality hints only). Includes
  `runtime_sized_binding_policy` so runtime-sized storage bindings
  resolve to `host_copied` (WebGPU) or `fabric_streamed_with_loader`
  (WSE-3) rather than an implicit choice.
- `mod.zig` — descriptor hash helpers that participate in realization
  identity.

Schema + contract surfaces under `config/`:

- `doe-tsir-semantic.schema.json` — canonical JSON shape for TSIR
  semantic artifacts including RMSNorm body contract.
- `doe-tsir-realization.schema.json` — canonical JSON shape for TSIR
  realization artifacts including residency decisions, tile factors,
  and reduction tree nodes.
- `doe-tsir-manifest-lowering.schema.json` — manifest binding entry
  shape: `(kernelRef, backend, targetDescriptorCorrectnessHash,
  tsirSemanticDigest, tsirRealizationDigest, emitterDigest,
  exactness, rejectionReasons)`.
- `doe-parity-receipt.schema.json` — parity CLI receipt shape.

Bench tooling + fixtures:

- `bench/tools/doe_parity.py` — manual parity CLI gate. The narrow
  bootstrap reference lane computes real oracle hashes for fused_gemv,
  rms_norm, and gather input JSON through the built Zig
  `doe-tsir-bootstrap-oracle` subprocess. Backend execution lanes remain
  `not_implemented` / `deferred` until WebGPU and CSL simfabric
  execution harnesses land.
- `bench/tools/tsir_manifest_lowering.py` — schema-backed builder for
  `integrityExtensions.lowerings[]` entries.
- `bench/fixtures/tsir-manifest-entries/` — bootstrap manifest-lowering
  fixtures pairing the three bootstrap families against both
  `webgpu-generic` and `wse3` target descriptors.
- `bench/gates/nightly_tsir_parity_canary.py` — advisory nightly canary
  that drives the bootstrap fixture set through the parity CLI without
  promoting stub backend lanes to a claim.
- `runtime/zig/tests/tsir/bootstrap/` — pinned `.wgsl`, hand-sketched
  `.tsir-semantic.json`, and per-target `.tsir-realization.*.json`
  plus `.notes.md` for each bootstrap family.
- `runtime/zig/src/compiler/tsir/tools/tsir_bootstrap_manifest_inputs.zig` — build-step
  entrypoint invoked by `bench/tools/generate_tsir_manifest_fixtures.py`
  via `zig build tsir-bootstrap-manifest-inputs` to materialize the
  canonical digest inputs the Python builder pairs with target descriptor
  hashes and emitter-code digests.
- `runtime/zig/src/compiler/tsir/tools/tsir_bootstrap_oracle.zig` — build-step entrypoint
  invoked by `bench/tools/doe_parity.py` via `zig build
  tsir-bootstrap-oracle` so the parity CLI's bootstrap reference hashes
  come from Zig `tsir.reference.run` rather than Python-local math.

Rejection taxonomy is locked across five surfaces — the Zig canonical
enum, the Python CLI's `REJECTION_REASONS`, and the three JSON schemas
that carry rejection enums — by a cross-schema lockstep test; the Zig
enum is additionally locked by a scaffold test for exhaustiveness.

The missing work is backend execution wiring in the parity CLI, AOT
convert-time lowering with a correctness-input cache key, parity-iteration
per-family parity receipts under
`reports/parity/`, manifest-binding of those receipts into Doppler's
`integrityExtensions.lowerings[]`, and the attention phase (Phase B)
with its sollya transcendental determinism.

## Design rules

The plan keeps five rules fixed:

1. The parity oracle is the definition of correctness. Backends compare against
   the oracle, never against each other.
2. Exactness classes reuse RDRR vocabulary verbatim. No parallel taxonomy.
3. Lowering is manifest-bound and hashable. Compiler policy is not allowed to
   drift silently.
4. Unsupported kernels fail closed with typed rejection reasons.
5. The manual parity CLI is the gate. This is not a CI-first design. A nightly
   canary parity run on a fixed kernel set is allowed as low-cost regression
   insurance; PR-gating CI is still out.

## Scope and phasing

This section has been re-scoped to target Cerebras parity for the Gemma
family specifically, not full cross-backend portability. The original draft
treated TSIR as a symmetric compiler that emits for five backends and
validates each against a scalar reference oracle. That scope is not
wrong architecturally, but it is wider than what the downstream Doe-Doppler
path actually needs. The five re-scope moves are:

1. **Invert the reference dependency for real kernels.** Doppler's browser
   WebGPU runtime already emits a `doppler.reference-transcript/v1` per
   real Gemma run via the `doppler bundle` composition path. That is
   ground truth for "this is what the model does" and is shipped, not
   planned. Use the Doppler transcript as the reference for real-kernel
   parity; the Zig scalar reference interpreter stays authoritative only
   for the bootstrap catalog (fused_gemv, rms_norm, gather) where the
   oracle exists as a small self-contained program.

2. **TSIR → CSL is the critical path; other backends are optional.** The
   emitters under `runtime/zig/src/compiler/tsir/emit_{csl,webgpu,msl,dxil,spir_v}.zig`
   collectively cover five targets. WS3's downstream consumer is CSL
   (the Cerebras lane WS4 owns). Doppler already produces WGSL, so
   TSIR → WebGPU is a consistency check, not a functional requirement.
   Only TSIR → CSL must reach body-level parity on real kernels. MSL,
   DXIL, SPIR-V, and `webgpu-generic` stay at their current
   semantic-aware-where-bootstrap / skeleton-elsewhere level; body
   parity for those backends is post-WS3 work.

3. **AOT convert-time lowering (step 11) moves forward of kernel-family
   rewrites (step 9).** Step 11 is the mechanism that forces TSIR to
   cover whatever real kernels a real model uses, because convert-time
   lowering must either emit a receipt per kernel or fail closed with a
   typed rejection. Pulling it forward collapses steps 9 and 10 into
   one flow (receipts fall out of convert at the Doppler boundary)
   and makes frontend coverage model-driven rather than
   family-sequence-driven.

4. **Live HostPlan coverage drives real-kernel selection.** Earlier
   drafts treated `embed`, `lm_head_gemv`, `attn_head256`, and
   `attn_head512` as the immediate 3 1B blockers because they overflowed
   per-PE memory. That evidence is stale for 3 1B: those kernels now
   compile at the current manifest scale. The real-kernel TSIR order
   should follow the kernels still hand-maintained in the live HostPlan
   and the failures surfaced by the simulator loop, with bounded
   residency kept as the 31B scale constraint rather than the first 3 1B
   unblock.

5. **Phase B (attention) narrows to the one variant the target model
   uses.** The previous draft framed attention as its own full phase
   with flash semantics, sliding-window, paged KV, and
   transcendental-determinism via sollya polynomials. WS3's exit
   condition only requires the attention variant Gemma 4 E2B actually
   uses. Ship that first; additional attention variants become
   follow-on work, not WS3-closing work. Sollya polynomials move to
   Phase C (when the second attention variant or the second transformer
   family lands), not Phase B.

Under these five moves, WS3 closure is defined by the live model kernels going
through TSIR -> CSL with parity receipts bound into the live Doppler manifest.
Parity is CSL-vs-Doppler-transcript, not CSL-vs-Zig-oracle.

### Phases under the re-scope

- **Phase A — bootstrap pipeline proof (largely landed).** Zig scalar
  reference interpreter, target descriptors, TSIR schema, frontend for
  the bootstrap catalog, planner, collective synthesis, mechanical
  emitters (CSL + WebGPU bodies; others skeleton), parity CLI reference
  lane, manifest binding. Remaining: either wire `webgpu-generic` lane
  for bootstrap as a CSL-consistency check, or label it
  "compare-to-Doppler-transcript" and reuse the Doppler reference. The
  nightly canary remains advisory.

- **Phase A.5 — AOT convert-time lowering at the Doppler boundary.**
  Step 11 promoted here. Doppler's convert stage invokes TSIR lowering
  for the manifest's execution graph; emits a lowering entry per
  `(kernelRef, backend)` plus a parity receipt compared against the
  Doppler reference transcript. Fails closed with typed rejection
  reasons when a kernel cannot be lowered. This is the mechanism that
  forces TSIR frontend coverage to grow with real models.

- **Phase B — hand-maintained Gemma kernel migration.** TSIR frontend +
  reference interpreter coverage for kernels still maintained through
  special CSL emitters in the live HostPlan, including tiled matmul,
  rope, GEMV/lm-head, attention, sample, fused FFN, and embed/gather as
  needed. Parity receipts bind into the Gemma manifest at convert time.

- **Phase C — bounded residency and scale.** Apply the TSIR residency
  model to the kernels that become memory-shaped at E2B/31B scale,
  especially embed, lm-head, and attention. No flash-style variants, no
  sliding-window, no paged KV unless the target model itself uses them.
  Exit: the full kernel set has CSL parity receipts against Doppler
  transcripts at the target scale.

- **Phase D — follow-on** (post-WS3): additional attention variants,
  sollya-based cross-platform transcendental determinism, TSIR →
  WebGPU/MSL/DXIL/SPIR-V body parity, autotuning.

Claims tightened from the previous draft:

- "3–6 months" / "12–18 months" estimates removed. Scope is defined by
  exit conditions, not calendar.
- "zero local decisions" becomes "no kernel-family pattern-matching;
  conflict resolution enumerated and hashed". Named in step 7.
- "stable semanticDigest" becomes "stable under pinned frontendVersion".
  Named in step 3.
- "no CI" becomes "no PR-gating CI; nightly canary parity on a fixed
  kernel set". Named in step 8.
- "kernel-family hints bias heuristics" becomes "hints are tiebreakers
  only; never change feasibility or rejection". Named in step 4.
- The previous Phase A target "WSE-3 and WebGPU generic, with parity
  receipts for non-attention kernels" is retained for bootstrap
  kernels only. Real-kernel parity target narrows to CSL.

## Step 1: parity oracle before any compiler work

The parity oracle is split into two regimes under the re-scope:

**Bootstrap regime (this step, as originally written).** The scalar
reference interpreter at `runtime/zig/src/compiler/tsir/reference_interpreter.zig`
is the oracle for the bootstrap catalog (`fused_gemv`, `rms_norm`,
`gather`). It consumes WGSL-derived TSIR, not backend code, and defines
what counts as correct before any emitter gets a vote. The interpreter
executes with declared IEEE-754 semantics, left-fold reduction order
unless a reduction explicitly permits a declared tree, and fp32
accumulation for reductions unless the source overrides it. The
interpreter stays authoritative for the bootstrap catalog because
those kernels are small enough for a scalar oracle to re-derive and
because the oracle-as-a-real-program property is exactly what the
bootstrap regime is supposed to prove.

**Real-kernel regime (the inversion).** For real Gemma kernels, the
reference is Doppler's `doppler.reference-transcript/v1` from a
browser WebGPU run of the same kernel on the same inputs. That
transcript ships from `doppler bundle` with per-step logits hashes and
KV identity, executing on the same WGSL the manifest already names.
Using the transcript as reference removes the requirement that the
Zig interpreter re-derive correctness for every new kernel family;
the interpreter does not need to cover `attn_head256` or
`lm_head_gemv` body arithmetic because Doppler already has.
The parity CLI (step 8) accepts either oracle source depending on the
kernel class: bootstrap kernels route to the Zig oracle; real kernels
route to the Doppler transcript.

The invariant that a backend is never validated by comparing it to
another backend still holds. Both oracles (Zig scalar for bootstrap,
Doppler transcript for real) are orthogonal to any backend under
test. Backends compare to the oracle, not to each other.

**Determinism requirement, named:** the project requires cross-platform
bit-identity because Doppler WebGPU runs on heterogeneous browser GPUs. The
end-state interpreter uses sollya-bounded minimax polynomials for
transcendentals (exp, log, sin, cos, tan, tanh, rsqrt, recip) with declared
worst-case ULP bounds. Shipping sollya polynomials is a several-month
sub-project of its own and is therefore scheduled as Phase B work, not
Phase A.

**Phase A bootstrap:** Phase A ships with pinned-libc determinism — the caller
pins the glibc version used to compute reference results, and the nightly
canary (step 8) runs on that same pinned libc. Any kernel whose correctness
depends on a transcendental is declared `tolerance_bounded` with a named
metric and epsilon; no kernel silently uses libm-adjacent math under
`bit_exact_solo` or `algorithm_exact`.

**Phase B upgrade:** sollya polynomials land as part of Phase B when attention's
softmax needs cross-platform exp determinism at scale. Kernels that were
`tolerance_bounded` in Phase A for transcendental-only reasons can then be
re-declared `algorithm_exact` with the sollya tree shape recorded in the
`algorithm_exact` invariants (see step 6). Existing Phase A parity receipts
remain valid for their declared class; the upgrade is a new receipt, not a
retrofit of old ones.

Every later compiler step depends on this oracle existing as a real program,
not a comment. Without it, "faithful lowering" is undefined and backend drift
can only be measured relative to another backend. That is not good enough for
proof-bound runtime claims.

## Step 1.5: bootstrap kernel catalog before the full frontend

Before the full WGSL -> TSIR frontend is written, Doe should pin a deliberately
small bootstrap catalog of WGSL kernels and their expected TSIR shapes:

- one fused-GEMV variant
- one RMSNorm variant
- one gather variant

The point is not performance. The point is validating that the TSIR schema, the
parity oracle, and the target-descriptor shape can actually represent the first
three nontrivial kernel families the project intends to lower. This catches
category errors early, before the frontend locks in assumptions that force
schema churn later.

These bootstrap kernels should live as explicit test fixtures with hand-sketched
expected TSIR summaries so the first frontend work is judged against concrete
representability rather than prose alone.

## Step 2: target descriptors as data, not backend code

Target properties must be explicit descriptors consumed by planning passes, not
hidden emitter assumptions. The first descriptor should cover WSE-3 and expose
the fields the planner actually needs: per-PE working and persistent memory,
fabric colors, collective limits, lane/sub-tile width, native collective set,
supported numerical modes, dequant helpers, streaming primitives, and latency
or cost hints the planner may consult. A second descriptor should capture a
generic WebGPU target surface with subgroup bounds, workgroup memory, and
storage/buffer limits.

The point is not to abstract all hardware differences away. The point is to
make them explicit, versioned, hashable inputs to realization. New hardware
should add a new descriptor, not force hidden compiler rewrites.

Descriptor fields should be split into two classes:

- `descriptor.correctness`
  - correctness-affecting fields that participate in lowering identity
  - examples: supported collectives, lane width, supported dtypes, memory
    budgets, exactness-relevant collective properties
- `descriptor.planner`
  - planner-affecting fields that influence search quality but should not, by
    themselves, invalidate manifests
  - examples: latency hints, bandwidth estimates, cost priors, autotuning hints

Only correctness-affecting descriptor fields should flow into the realization
identity. Planner hints are inputs to search quality, not semantic identity.

## Step 3: TSIR schema with semantic and realization digests

TSIR needs two stable layers with two different digests.

`tsir.semantic` is the backend-independent meaning of the kernel:

- loop nests and iteration axes
- affine bounds where analyzable
- buffer bindings and logical shapes
- reduction regions and numerical contract
- collective nodes
- source hash back to WGSL IR
- family hints that bias heuristics but do not select emitters

`tsir.realization` is the backend/target-specific plan:

- tile factors
- residency choices
- PE-grid shape
- reduction tree shape
- collective mapping details
- target descriptor hash
- emitter parameters
- emitter digest

The in-tree scaffold already models this split. The real work is making the
canonical JSON and digests production-grade and then binding them into the
manifest/lowering receipts.

One caveat needs to be explicit: `semanticDigest` is not "stable forever." It
is stable under a pinned frontend version and semantics-preserving frontend
evolution. If loop recovery, subgroup canonicalization, or dependence analysis
changes semantic TSIR, then semantic identity changes and the manifest must pin
that through an explicit `frontendVersion` input. That turns frontend
improvements into declared migrations instead of silent semantic drift.

## Step 4: WGSL frontend to TSIR lowering

The current CSL route collapses too early from IR into classifier tags and
template parameters. The replacement path is WGSL IR to TSIR.

That means a real frontend pipeline:

- SSA-friendly control-flow normalization
- induction-variable recovery
- affine/dependence analysis where possible
- reduction-region identification
- buffer-binding shape and access summary extraction
- subgroup canonicalization into collective nodes

Classifier logic does not disappear entirely. It shrinks into a kernel-family
hint on the TSIR function so planning heuristics can bias search without
hard-selecting an emitter. Sources that cannot be represented faithfully must
reject with typed taxonomy reasons instead of having semantics dropped or
silently simplified.

The bound on hints should be strict: hints may act as tie-breakers between
already-feasible plans, but they must never change feasibility or rejection.
If a kernel does not fit without a hint, the hint is not allowed to "rescue"
it. That keeps TSIR planning honest and prevents hidden special-casing from
re-entering through heuristic backdoors.

## Step 5: residency and allocation planning

This is where the current non-GEMM failures actually get fixed. The issue is
not that WSE-3 is incompatible with these kernels. The issue is that current
emitters materialize buffers per PE that should instead be sliced, streamed, or
recomputed.

The residency pass consumes `tsir.semantic`, a target descriptor, and loader
capabilities. It computes liveness, interference, and fit. For each binding and
intermediate, it chooses one of a small declared set:

- `pe_replicated`
- `pe_sliced`
- `fabric_streamed`
- `host_copied`
- `recomputed`

Tile search should stay bounded and deterministic. It does not need a full
polyhedral framework. It does need explicit fit decisions and explicit failure
reasons. If no fitting plan exists, the compiler rejects with
`tsir_pe_budget_exhausted` and records the specific overflow source.

This first planner should be documented honestly as a correctness-first
planner. A bounded first-fit search over a small tile space is enough to prove
representability and fit, but it is not enough to promise good non-GEMM
throughput. Autotuning and broader cost search belong later, after the kernel
families are actually lowered through TSIR.

This pass also has an external dependency boundary: some streaming decisions are
not only compiler questions. They depend on RDRR packaging. A tensor cannot be
planned as `fabric_streamed` if the bundle packaging does not expose the needed
Merkle or shard granularity. That means some kernel families will require both:

- TSIR/compiler work in Doe
- packaging policy work in Doppler/RDRR

Examples of that coupling:

| Kernel family | Packaging dependency |
| --- | --- |
| fused GEMV with streamed weights | tensor isolation and sufficiently fine Merkle/block granularity |
| gather with streamed embedding | embedding tensor isolated from unrelated co-packed tensors |
| attention with paged KV | explicit KV packaging contract compatible with paged or streamed residency |

## Step 6: collective synthesis and numerical contract

Subgroup and barrier behavior needs a first-class lowering pass rather than
template-local interpretation. `workgroupBarrier` becomes an explicit sync
point. Subgroup reductions and scans become explicit collectives over a declared
lane or sub-tile mapping. Broadcasts, ballots, shuffles, and reductions each
need declared semantics, not inferred "best effort" behavior.

This is also where numerical exactness gets pinned:

- accumulation dtype
- reduction order or declared tree
- reduction-tree shape
- NaN and Inf propagation
- exactness class

If a collective cannot be represented on a target without violating the
declared contract, the pass rejects it. That keeps fail-closed behavior intact
while making subgroup-to-fabric lowering a compiler responsibility instead of an
unsupported gray area.

For `algorithm_exact`, the declared invariants must include more than "same
operation family." They need to include the properties that actually affect
floating-point bits:

- reduction order
- tree shape
- accumulation dtype
- allowed associativity grouping

Two lowerings can share one semantic TSIR and still produce different bits if
their realization chooses different reduction trees. That is valid only when
the exactness contract declares it.

## Step 7: one mechanical TSIR-to-CSL emitter

CSL is the critical-path backend under the re-scope. The other four
emitters (`emit_webgpu.zig`, `emit_msl.zig`, `emit_dxil.zig`,
`emit_spir_v.zig`) stay at their current level — semantic-aware
bootstrap bodies where they exist, skeleton-only elsewhere — and do
not gate WS3 closure. Body parity for those backends is post-WS3 work.

Once planning is explicit, the emitter should stop making decisions. It should
be mechanical.

The emitter consumes `tsir.realization` and a target descriptor and emits:

- declarations based on residency class
- loop structure from tile factors
- PE program scaffolding from grid shape
- collectives from collective nodes
- parameter blocks from resolved emitter parameters

The key constraint is not "zero local decisions" in the absolute sense. The
real constraint is:

- no kernel-family pattern matching in the emitter
- no hidden semantic rescue logic in the emitter
- any conflict-resolution behavior that remains local to emission must be named,
  enumerable, and hashed into emission identity

That leaves room for emitter-local conflict handling where the hardware requires
it, such as DSD layout details, fabric-color conflicts, or bank-conflict
workarounds, without turning the emitter back into a semantic planner. If the
emitter has to decide whether something is replicated, sliced, streamed, or
reduced, the earlier passes have already failed architecturally.

The current per-kernel CSL emitters can remain as migration shims while kernels
move over one family at a time, but the end state is a shared lowering
pipeline feeding a small number of mechanical backend emitters.

### Per-PE memory constraints for scale kernels

The CSL emitter body for scale kernels must honor per-PE memory constraints
(see `docs/status/cerebras-csl.md`). This is not an optional optimization, but
the immediate evidence has changed: these kernels compile at Gemma 3 1B scale
after the current HostPlan fixes, while 31B still needs the residency model to
be explicit and compiler-owned. The emitter path for each scale-sensitive
kernel is:

- **`embed`**: 2D grid with `hidden_per_pe` sharding plus host-chunked
  dispatch. The emitter reads residency class from the planner, not
  from a local heuristic.

- **`lm_head_gemv`**: 2D layout with
  `out_dim_per_pe = ceil(out_dim / height)`. The planner decides the
  grid shape based on the target descriptor's `per_pe_working_budget`;
  the emitter honors it.

- **`attn_head256` / `attn_head512`**: host-streamed K/V tiles replace
  PE-resident `key`/`val` arrays. The planner declares a
  `stream_kv_tiles` residency class on the KV tensors; the emitter
  consumes that class and emits `@fmovs` from host-fabric rather than
  flat per-PE storage.

These patterns are expressed as residency-class + collective-synthesis
decisions in steps 5 and 6, not as kernel-specific logic in the
emitter. The emitter remains mechanical — it just consumes a richer
residency taxonomy than the bootstrap catalog exercised.

## Step 8: manual parity CLI as the gate

Parity is a manual CLI gate, not a PR-gating CI policy. The CLI routes
each kernel to the oracle its regime declares — the Zig scalar
reference interpreter for the bootstrap catalog, Doppler's
`doppler.reference-transcript/v1` for real kernels — and compares each
backend result under a declared exactness class. The output is a
parity receipt with hashes, exactness class, pass/fail status, the
reference-source identity, and explicit rejection reasons.

The important property is asymmetry: a backend is never validated by
comparing it only to a different backend. Both compare to the oracle.
Under the re-scope, "the oracle" has two concrete implementations:

- **Zig scalar reference** for bootstrap (`fused_gemv`, `rms_norm`,
  `gather`). Receipt carries `referenceSource.kind = "zig-tsir-oracle"`
  plus the oracle binary's commit-bound identity.
- **Doppler transcript** for real kernels. Receipt carries
  `referenceSource.kind = "doppler-reference-transcript"` plus the
  transcript's `executionGraphHash` and `source.hash` so the reference
  is reproducible from the manifest-bound bundle.

If no oracle exists for a kernel family yet (no bootstrap oracle
coverage, no Doppler transcript because the kernel is not captured),
that family is not eligible for proof-grade promotion.

### Backend lane rules under the re-scope

- **`csl-simfabric`** is the critical-path backend lane. Real-kernel
  parity receipts require it green (or explicitly rejected with a
  typed reason). Execution runs against the local SDK container (see
  `docs/status/cerebras-csl.md`; the prior
  `csl_compile_container_runtime_blocked` classification is stale on
  current hosts).
- **`webgpu-generic`** is optional for real kernels under the re-scope.
  Two acceptable modes: (a) execute through the TSIR → WebGPU emitter
  and compare to the reference, or (b) declare the webgpu lane as
  `reference-is-webgpu` and skip the TSIR emission, since Doppler's
  browser WebGPU run already produced the reference. Mode (b) is valid
  for real kernels; mode (a) is required for bootstrap kernels where
  there is no Doppler transcript.
- **`wse3` / `msl` / `dxil` / `spir-v`** skeleton lanes stay at current
  state. Their receipts continue to carry `status=deferred,
  reason=backend=skeleton_only` until a downstream consumer needs body
  parity.

### Avoiding PR-gating CI

The reason for avoiding PR-gating CI here is practical rather than ideological:

- full reference interpretation is expensive on large kernels
- simfabric-backed runs require provisioned infrastructure
- most repo changes do not touch lowering
- existing promoted non-TSIR artifacts already have their own parity gates;
  TSIR convert-time parity is introduced by this plan, not assumed as current
  state

That still leaves room for lightweight automation. A fixed nightly canary set
is compatible with this plan and should be preferred over broad PR gating:

- one fused-GEMV kernel
- one RMSNorm kernel
- one gather kernel
- one real Gemma kernel from the live HostPlan using the
  Doppler-transcript reference path
- later, one attention-decode kernel for Gemma 4 E2B

That gives cheap regression coverage without turning every routine change into a
full lowering/parity farm run.

## Step 9: rewrite kernel families in impact order

Migration order under the re-scope is driven by the live HostPlan and
simulator evidence, not by the stale 3 1B memory-blocker list. The
remaining hand-maintained families to move through TSIR are:

1. tiled matmul
2. `attn_head256`
3. `attn_decode`
4. GEMV / `lm_head_gemv`
5. rope
6. `fused_ffn`
7. sample
8. embed/gather

Each migrated
family still crosses the full bar in one move: TSIR lowering,
mechanical emission, parity receipt, then deletion of the old path
for that family. Half-migrated kernel families create audit holes and
should be avoided.

Attention is still treated as its own phase (Phase C under the
re-scope), but narrowed to the one variant Gemma 4 E2B uses. Flash
the first non-GEMM migration wave. Streaming attention, paged KV, sliding
window policies, and streaming softmax reductions are distinct compiler
problems. The non-attention phase proves the TSIR pipeline on GEMV, RMSNorm,
and gather. Attention then becomes the next architecture phase built on top of
that proven pipeline rather than a hidden assumption inside the first rewrite
sequence.

## Step 10: manifest-bound lowering receipts

Lowerings need to be part of the portable-program artifact boundary. The
manifest should bind:

- kernel reference
- backend
- target descriptor hash
- frontend version identity
- TSIR semantic digest
- TSIR realization digest
- emitter digest
- compiler version identity
- exactness class
- rejection reasons when a backend cannot honor the kernel

That keeps compiler policy from becoming a hidden runtime behavior. Replay
should be able to say not only "these weights and this graph ran" but also
"this exact lowering of this exact kernel ran." Compiler upgrades then become
explicit migrations and refreshed lowerings, not silent semantic drift.

## Step 11: AOT lowering at convert time

Promoted under the re-scope: step 11 runs ahead of the real-kernel
family rewrites (step 9), not after them. The reasoning is that
AOT-at-convert is the only mechanism that forces TSIR to cover
whatever kernels a real model actually uses. Without it, kernel-family
selection becomes a scheduling decision ("which family do we migrate
next?") that can drift from what real models need. With it, running
`doppler convert` (or `doppler bundle`) on a Gemma model produces
lowering entries per `(kernelRef, backend)` and fails closed with a
typed rejection on any kernel TSIR cannot yet lower — which is what
drives frontend/oracle/emitter coverage forward.

Promotion also collapses steps 9 and 10: real-kernel rewrites land
when their parity receipts fall out of convert, not as a separate
"rewrite the family" milestone.

Lowering should run ahead of time during conversion or refresh, not at load.
The bundle should ship with emitted backend artifacts and the receipts that
justify them. A backend that cannot honor a kernel should record the rejection
reason in the manifest-side lowering metadata, so runtime refusal is immediate
and explicit.

This keeps the runtime boundary small. The runtime becomes a loader and
executor of predeclared lowerings rather than a place where planning and policy
quietly happen on first token. It also keeps proof and replay discipline
aligned with the existing Doppler manifest-first model.

### Doppler convert integration

The concrete wiring: Doppler's `convert` stage (and the `doppler bundle`
composition that invokes it) calls into Doe's TSIR lowering for each
kernel declared in `manifest.inference.execution.kernels`. For each
`(kernelRef, backend)` in the target matrix, convert emits:

- a lowering entry under `integrityExtensions.lowerings.entries[]`
  with the full identity tuple (target descriptor hash, TSIR semantic
  digest, TSIR realization digest, emitter digest, compiler version,
  exactness class, rejection reasons)
- a parity receipt under `reports/parity/<kernelRef>.<backend>/` with
  `referenceSource` naming whether this kernel is gated against the
  Zig oracle (bootstrap) or a Doppler reference transcript (real)
- a typed rejection when TSIR cannot lower the kernel for that
  backend (for example, an unsupported op or a target descriptor
  mismatch), so convert fails-closed rather than shipping a bundle
  with gaps

The target matrix under the re-scope is:

- `csl-simfabric` (critical path for WS3)
- `webgpu-generic` in mode (b) from step 8 — the lowering entry names
  the reference transcript's identity and the TSIR realization for
  replay, but does not emit WGSL (Doppler's WGSL is authoritative)
- `wse3` / `msl` / `dxil` / `spir-v` stay skeleton-only receipts

Per-backend AOT emission does increase convert cost, especially for large model
families and multiple backend variants. That should be handled explicitly with
per-kernel lowering cache keys derived from correctness-relevant inputs such as:

- WGSL/kernel identity
- target correctness descriptor
- frontend version
- compiler version
- emitter version

That keeps repeated variants from paying the full lowering cost when the kernel
and lowering identity have not changed.

## Step 12: rollout and steady state

The rollout order under the re-scope is:

1. parity oracle — dual regime (Zig scalar for bootstrap; Doppler
   transcript for real kernels)
2. bootstrap kernel catalog (step 1.5) — one fused-GEMV, one RMSNorm,
   one gather
3. target descriptors (correctness + planner field split)
4. TSIR schema hardening and canonical digests
5. WGSL frontend lowering
6. residency/allocation (correctness-only planner; richer residency
   taxonomy for real kernels — `hidden_per_pe`, `out_dim`,
   `stream_kv_tiles`)
7. collective synthesis
8. mechanical CSL emitter (body parity for critical path; other
   emitters stay semantic-aware-where-bootstrap / skeleton-elsewhere)
9. manual parity CLI with dual reference source (oracle vs. Doppler
   transcript) plus nightly canary on a fixed kernel set
10. manifest binding (includes frontendVersion, descriptor correctness
    hash, reference-source identity)
11. AOT convert-time lowering at the Doppler boundary — this drives
    real-kernel coverage; promoted ahead of the rewrite step
12. real-kernel family rewrites — driven by step 11 hitting real
    models and by the simulator failure loop. The remaining
    hand-maintained live HostPlan kernels move through TSIR first; the
    bounded-residency kernels become scale work when E2B/31B requires
    them.

### Build-iteration sub-tracks

The sub-tracks below are scheduling labels for the rollout order above.
They do not change the ordering, and they do not permit an iteration to skip
the lowest-numbered unfinished rollout item. Each build iteration still lands
one committable compiler-only increment, with tests, schema or contract updates
where required, and a dated status entry.

- **Track A: oracle, catalog, and descriptors.** Owns rollout items 1-3:
  parity oracle, bootstrap kernel catalog, and `webgpu-generic` / `wse3`
  target descriptors.
- **Track B: TSIR contract hardening.** Owns rollout item 4: schema
  hardening, canonical JSON, semantic digest, realization digest, exactness
  vocabulary, and rejection taxonomy.
- **Track C: WGSL frontend lowering.** Owns rollout item 5: WGSL IR to TSIR
  semantic lowering, including binding/shape extraction, axis recovery,
  reduction detection, family hints, and typed rejection for unanalyzable
  kernels.
- **Track D: residency and allocation planning.** Owns rollout item 6:
  correctness-first residency, allocation, liveness, and bounded tile search.
- **Track E: collective synthesis and numerical contract.** Owns rollout item
  7: collective nodes, reduction tree shape, accumulation dtype, and exactness
  invariants.
- **Track F: mechanical backend emission.** Owns rollout item 8: backend
  emission from `tsir.realization`, with no hidden kernel-family semantic
  rescue logic.
- **Track G: parity CLI plumbing.** Owns rollout item 9 as infrastructure
  only. Real parity closure remains the parity-iteration stream; legacy
  classifier receipts do not satisfy a parity iteration.
- **Track H: manifest metadata + AOT convert plumbing.** Owns rollout
  items 10 and 11 as Doe-side infrastructure plus the Doppler-side
  convert integration: lowering metadata shape, rejection serialization,
  correctness-input cache keys, Doppler convert invocation of TSIR
  lowering, and reference-source routing in the parity CLI. This sub-track
  lands before real-kernel family rewrites under the re-scope.
- **Track I: real-kernel family rewrites.** Owns rollout item 12 for
  live HostPlan kernels that still depend on hand-maintained CSL
  emitters. Driven by Track H's convert-time coverage and the simulator
  failure loop. Each kernel family lands with a CSL body that honors
  declared TSIR residency constraints and a parity receipt against a
  Doppler reference transcript.
- **Track J: steady-state cleanup.** Deletes migrated per-kernel CSL
  emitters and reduces classifier logic to kernel-family hint
  extraction for migrated families.

The build stream has no production Doppler manifest mutation and no live
Cerebras SDK dependency in its inner iteration. It may define `wse3` target
descriptors, but simulator execution belongs to the parity-iteration stream
or evidence work.

Steady state is simple:

- a new kernel family means WGSL plus parity-backed lowering support
- a new backend means a descriptor and emitter support, not a new compiler
  architecture
- a compiler change means a new lowering digest and refreshed receipts

That is the difference between "one program, many faithful realizations" and
"one source language with many backend-specific template piles."

## Relationship to current Doe docs

This plan extends, but does not replace, the current architecture docs:

- `docs/shader-compiler-architecture.md`
  - current WGSL compiler pipeline
- `docs/csl-architecture.md`
  - current CSL classifier/HostPlan/emitter path
- `docs/doppler-ingest.md`
  - Doppler-owned program boundary and Doe-owned lowering boundary
- [`docs/loop-protocol.md`](loop-protocol.md)
  - build-iteration vs parity-iteration discipline that drives how this
    plan lands incrementally
- [`docs/status/tsir.md`](status/tsir.md)
  - live status for this plan's implementation — what's landed per
    step and what work remains before proof-1

The operative current state remains:

- WGSL -> Doe IR -> backend emission for Metal/Vulkan/D3D12
- WGSL/Doppler capture -> classifier -> HostPlan -> CSL emitter for Cerebras

The target state defined here, as re-scoped, is:

- WGSL IR -> TSIR semantic -> TSIR realization -> CSL emitter (critical
  path for Cerebras parity)
- dual-regime parity: Zig scalar oracle for bootstrap kernels; Doppler
  reference transcripts for real kernels
- AOT convert-time lowering emits receipts + manifest bindings as a
  side effect of `doppler convert` / `doppler bundle`
- other backend emitters (webgpu-generic, msl, dxil, spir-v) remain at
  their current level; body parity for those is post-WS3

Until that target path is wired end to end, current classifier/template
limitations remain real blockers rather than documentation-only issues.

## WS3 closure condition

WS3 is closed when `doppler bundle` for `gemma-4-e2b-it-q4k-ehf16-af32`
produces:

- `reports/parity/embed.csl-simfabric/` — pass against Doppler transcript
- `reports/parity/lm_head_gemv.csl-simfabric/` — pass
- `reports/parity/attn_head256.csl-simfabric/` — pass (or rejected
  with typed reason if Gemma 4 E2B does not use this variant)
- `reports/parity/attn_head512.csl-simfabric/` — pass (or rejected
  with typed reason if Gemma 4 E2B does not use this variant)
- `reports/parity/` entries for rope / rmsnorm / elementwise /
  dequant / sample as `doppler bundle` touches them via AOT lowering
- `integrityExtensions.lowerings.entries[]` bound into the Gemma 4
  E2B manifest with full identity tuples

Bootstrap-kernel receipts (`fused_gemv`, `rms_norm`, `gather`) remain
green under the Zig oracle as a separate regression class; they do
not close WS3 on their own.
