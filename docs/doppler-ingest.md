# Doppler ingest

This document defines the Doe-owned side of the Doppler portable-program
boundary. Doppler owns the portable program export shape. Doe owns what it
accepts from that export, how it captures supported WebGPU execution, and how
it lowers supported WGSL into backend receipts.

The Doppler-owned export contract lives in
[`../../doppler/docs/integration/program-bundle.md`](../../doppler/docs/integration/program-bundle.md).
The wrapper-level narrative that composes the Doppler-Doe program boundary
with broader cross-repo context is owned upstream, not in this repo. Doe
docs intentionally describe only the Doe-local side of the boundary;
motivation and composition context stay in the upstream planning repo.

Doe does not compile arbitrary Doppler JavaScript. Doe accepts a closed,
versioned Doppler Program Bundle that declares its model identity, execution
graph, deterministic WebGPU command-producing entrypoint, WGSL modules and
digests, runtime profile, artifact identities, and reference transcript. Doe
configs select an exported bundle and a backend target; they do not re-declare
the kernels or execution behavior that Doppler already owns.

## Artifact ownership

| Artifact | Owner | Meaning |
| --- | --- | --- |
| Doppler Program Bundle | Doppler | Manifest and execution identity, packaged hash-bound WGSL and constrained host-JS bytes, runtime/capture profile, artifact IDs, and reference transcript. |
| WebGPU capture graph | Doe | Observed GPU command graph from running the declared program under a supported provider/capture profile. |
| TSIR semantic + realization | Doe | Two-level lowering contract between WGSL IR and backend emitters; semantic is target-independent, realization pins target + planner choices. Both are hashable; digests bind into `integrityExtensions.lowerings[]`. See `docs/tsir-lowering-plan.md` + `docs/status/tsir.md`. |
| HostPlan | Doe | Runtime orchestration contract for launches, tensors, scheduling, streams, and receipts derived from the declared/captured program surface. It is not the planned long-term place where kernel meaning, residency, or collective semantics are rediscovered. |
| CSL bundle and receipts | Doe | Backend output plus SDK compile, simfabric, parity, and hardware validation receipts. |
| Cross-repo CUJ narrative | Ouroboros | Milestone map and proof journey that links repo-local contracts without owning their fields. |

Ouroboros integration docs may link these artifacts into the critical user
journey, but the enforceable contract fields live with the owning repository.

## Lowering architecture

The Doe-owned lowering of a Doppler Program Bundle is not a single monolithic
boundary. It splits into two concerns at different levels of the stack:

1. **Kernel-level lowering — the TSIR contract.** `docs/tsir-lowering-plan.md`
   defines the compiler architecture: a Tiled Spatial IR between
   WGSL IR and backend emitters, with a parity oracle defined against TSIR
   rather than against any backend. TSIR is where tiling, residency,
   collectives, and numerical exactness become explicit once — instead of
   being rediscovered per-kernel by classifier/template emitters. The
   in-tree surface under `runtime/zig/src/compiler/tsir/` is the Phase A compiler
   surface for this plan (schema, digests, frontend, planner, reference
   interpreter, collective-synthesis pass, and five backend emitters
   whose realization-only entry points still serialize contract skeletons
   while their semantic-aware entry points emit executable bodies for the
   Phase A bootstrap families) — see `docs/status/tsir.md` for live
   status. The live CSL lane still routes through the classifier/template
   path, so the pipeline is not yet a completed replacement for that path.
2. **Runtime orchestration — the HostPlan contract.** HostPlan is the
   runtime-orchestration contract for launches, tensors, streams, and
   receipts. It is NOT the place where kernel meaning, residency strategy,
   or numerical semantics are rediscovered. Once TSIR is wired, HostPlan
   sits downstream of TSIR realization and consumes its decisions. See
   `docs/csl-architecture.md` for the CSL-specific HostPlan details.

For Doppler bundle ingest, this means lowering identity has two layers:

- semantic identity (what the kernel means, pinned by `tsir.semantic` and
  `frontendVersion`)
- realization identity (how it's lowered for a specific target, pinned by
  `tsir.realization`, `targetDescriptorCorrectnessHash`, and `emitterDigest`)

Both layers bind into the manifest under `integrityExtensions.lowerings[]`
per the TSIR plan, alongside the existing Doppler-owned source-program
identity. A bundle that crosses the CSL promotion boundary must present
parity receipts tied to both layers; HostPlan receipts alone do not
authenticate lowering choice once TSIR is live.

Until TSIR is wired end to end, the operative CSL lane still routes through
the classifier/template path and the existing HostPlan receipts. That is the
current truth, not the target truth. New CSL bring-up work should land with
TSIR in mind: kernel-family choices that would be rediscovered per-emitter
today should be expressible in TSIR tomorrow, and receipts should preserve
enough semantic context to retrofit TSIR digests without re-running the
source bundle.

## Reference implementation discipline

Doe may use external reference implementations, including Cerebras Model Zoo,
to inform architecture semantics, config interpretation, and checkpoint
expectations for a Doppler bundle. Those references are inputs to analysis and
parity work. They do not define Doe contracts.

The contract boundary is:

- external reference implementations may inform model semantics, config
  interpretation, checkpoint expectations, and parity attribution;
- they must not define Doe runtime contracts, transcript schemas, HostPlan
  shape, or CSL executor behavior.

Canonical truth for portability and parity comes from:

- exported weights and shard identities;
- tokenizer behavior;
- model config and manifest state;
- measured Doppler reference transcripts;
- papers only when the bundle and measured artifacts are insufficient.

When Doe consults a reference implementation, the allowed extracted facts are
architecture-facing only:

- block order;
- norm placement;
- attention type;
- KV/cache policy;
- MoE routing semantics;
- tensor naming correspondences;
- expected config fields.

Those facts must be normalized into Doppler-owned or Doe-owned portable
artifacts such as converter rules, normalized execution graphs, canonical
operator identities, and manifest metadata. Doe must not import
Cerebras-specific layer wrappers or execution assumptions as portable-program
truth.

The runtime leakage ban is explicit. Doe must not treat any of the following as
portable inputs merely because they appear in a reference implementation:

- CSL-specific kernels;
- SDK layout assumptions;
- Cerebras-only launch structure;
- device memory conventions;
- training-time fused shortcuts unless they are proven semantically identical
  to the declared Doppler program.

Reference implementations are valid for parity attribution when divergence is
reduced to architecture boundaries such as:

- embed;
- `q_proj` / `k_proj` / `v_proj`;
- attention score or value path;
- FFN up / gate / down;
- router logits;
- residual or norm boundaries.

Backends remain downstream of one declared program graph:

```text
Doppler semantics -> Doe normalized execution -> Doe WebGPU executor
Doppler semantics -> Doe normalized execution -> HostPlan / CSL executor
```

That is the current operational path. The in-flight migration path adds a
compiler-side lowering contract between WGSL IR and backend artifacts:

```text
Doppler semantics -> Doe normalized execution -> WGSL IR -> TSIR
WGSL IR -> TSIR -> WebGPU/backend lowering artifacts
WGSL IR -> TSIR -> HostPlan / CSL artifacts
```

In that target architecture, HostPlan remains the runtime orchestration
boundary for the CSL lane, but TSIR owns kernel-level lowering decisions such
as tiling, residency, collectives, and exactness. See
`docs/tsir-lowering-plan.md` for the lowering architecture (Phase A compiler
surface landed; `docs/status/tsir.md` has live status) and
`docs/csl-architecture.md` for the current HostPlan/classifier path that this
migrates from.

Reference-implementation agreement is not proof. Proof requires:

- a Doe WebGPU transcript;
- a CSL transcript;
- a strict parity receipt;
- hardware promotion only after simulator parity on the same bundle.

For every imported model family, Doe should keep drift tests that cover:

- config mapping;
- checkpoint and tensor-name correspondence;
- operator-boundary transcript checks;
- parity fixtures.

The hard review question for any such change is:

> Did this make Doppler more faithful, or did it make Doe more
> Cerebras-specific?

If the answer is the second one, the change should be rejected or rewritten so
the portable-program boundary stays intact.

## Version gates

Doe ingest must reject unsupported bundles early. A portable-program ingest
receipt should bind these fields before lowering:

- `schema` and `schemaVersion`
- `package.schema` and `package.fileSetHash`
- every `package.files[]` path, role, SHA-256, and byte size
- `sources.executionGraph.hash`
- `host.schema`, `host.jsSubset`, and packaged entrypoint source hashes
- every reachable `wgslModules[]` source path, source hash, and exact entrypoint
- `captureProfile.captureHash`
- `referenceTranscript.executionGraphHash`

The contract is fail-closed. A bundle that requires undeclared imports,
undeclared WGSL modules, hidden provider fallback, source paths outside the
bundle root, or runtime behavior outside the selected subset is not eligible
for CSL promotion.

## JavaScript boundary

The v1 JavaScript subset is deterministic WebGPU command production. Tokenizer
loading, prompt formatting, sampling policy, stopping rules, filesystem
loading, UI/browser concerns, and open-ended generation stay host-side unless a
future program-contract version explicitly admits them.

The first CSL proof target consumes declared token IDs and bounded decode
settings, then validates logits, selected token IDs, generated-token transcript,
and KV/cache evidence through receipts. Tree shaking or bundling may reduce the
program for execution, but it is an implementation detail, not the correctness
contract.

## Ingest modes

The declared Doppler execution graph is the source identity for v1 ingest. A
Doe WebGPU capture graph is evidence that a specific provider run produced the
expected command surface; it is not a replacement source of truth unless a
future contract version explicitly promotes capture-first ingest.

Doe.js remains optional from Doppler's perspective. Browser and Node Doppler
should remain WebGPU-first. Doe.js can act as an optional provider, capture, or
lowering surface for bundles that select Doe-compatible profiles.

Future direct-source lanes do not change that rule. Doe must not admit raw
`safetensors`, raw `gguf`, or any other raw source-format file as a CSL proof
input by itself. A direct-source lane is admissible only when Doppler exports a
closed Program Bundle over a materialized direct-source `manifest.json`.

For that future lane, Doe's ingest boundary stays normalized and bundle-first:

- `sources.manifest.hash` must bind the exact materialized manifest;
- the manifest must carry stable `metadata.sourceRuntime` identity, including
  `sourceKind`, `hashAlgorithm`, `pathSemantics`, source-file digests, and
  auxiliary/tokenizer asset digests;
- `sources.executionGraph.hash`, `sources.weightSetHash`, and the reference
  transcript remain the execution proof surface Doe binds into receipts.

Doe consumes the normalized portable-program facts exported by Doppler. Doe
does not derive HostPlan or CSL behavior from raw source-format metadata that
is not already represented in the bundle or its materialized manifest.

For portable ingest, `metadata.sourceRuntime.pathSemantics` must be
`artifact-relative`. `runtime-local` paths or incomplete digests are local
debugging aids only and are not eligible for CSL promotion.

## CSL promotion boundary

For a Doppler bundle to promote through Doe CSL, the receipts must show:

- the same manifest, graph, weight, shard, input, and prompt identities as the
  Doppler reference;
- a HostPlan and runtime config derived from the selected bundle, not a
  separate Doe-authored graph;
- SDK compile and simfabric execution from generated CSL/Python/SdkLayout
  artifacts;
- bounded transcript output with matching decode count, stop reason, token IDs,
  per-step logits tolerance, and generated-token sequence;
- observable KV/cache read/write and layer coverage evidence;
- no stub stages, synthetic inputs, synthetic weights, or hidden fallback path.

Hardware packaging starts only after the same bundle passes simfabric transcript
parity.
