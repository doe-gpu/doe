# Doe thesis

## What Doe is

Doe is a Zig-first WebGPU runtime and compiler for replacing hidden,
heavyweight GPU execution stacks with a source-preserving, receipt-backed
accelerator path.

Doe's core roadmap is two-pronged under that same source-preserving contract:

1. Chromium-family WebGPU implementation. Dawn is the WebGPU runtime baseline
   used in Chromium and most browser-shaped deployments; Tint is Dawn's shader
   compiler. Doe must beat that Dawn/Tint stack on claimable compiler, runtime,
   and browser-lane evidence, then become the best open-source WebGPU
   implementation path for Chromium-family browsers.
2. Doppler -> Doe -> Cerebras retargeting. Doe consumes a closed
   Doppler-authored Program Bundle, preserves the declared model/program
   identity through WGSL, TSIR, HostPlan, and CSL, then emits simulator and
   hardware receipts that prove what ran on the Cerebras lane.

Those targets do not mean Doe is already the browser default or that the
Cerebras lane already has hardware parity receipts. Package, embedded, native,
and server-side JavaScript lanes such as Node.js and Bun are proof ladders:
they establish strict methodology, hot-path behavior, compiler correctness,
traces, and receipts before claims promote into either roadmap prong.

One concrete integration lane for that scope is a Doe-backed ONNX Runtime
plugin EP — a native ML-host surface, not a claim that Doe has displaced
Chromium's runtime stack.

## Dominance objective

Doe's strategic target is dominance over the Chromium WebGPU incumbent stack:
Chromium as the browser integration surface, Dawn as the runtime incumbent, and
Tint as the shader compiler incumbent. That is an objective, not a standing
claim. Any specific "Doe beats Dawn/Tint/Chromium" statement must still pass
the claim gates and cite the artifact that proves it.

The architecture compresses into three goals:

1. Source-preserving execution plus multi-backend lowering equals program
   identity preservation.
   Doe must carry the same source/program identity through WGSL, Doe IR, TSIR,
   HostPlan, CSL, MSL, SPIR-V, DXIL/HLSL, and runtime command receipts. Beating
   Tint is not only a compiler-speed target; it also means producing auditable
   source-to-backend identity with less hidden compiler state.
2. The native WebGPU runtime path stays independent.
   `doe-zig-runtime`, `libwebgpu_doe`, and the package/native lanes are the
   actual runtime product surface. The Chromium lane should consume and prove
   that runtime at the `navigator.gpu` seam; it must not become the only place
   where Doe's runtime identity exists.
3. Receipt-backed claims plus compiler/proof discipline equals evidence and
   trust discipline.
   Compiler receipts, runtime traces, proof artifacts, benchmark reports, and
   browser-lane diagnostics are the trust surface. Narrative dominance does not
   count; artifact-backed dominance does.

The project goal is not "rewrite WebGPU in Zig" for its own sake. The goal is
to reduce hot-path CPU cost, keep runtime behavior explainable from config and
artifacts, and make correctness/performance claims reproducible.

## Core thesis

Doe is built around one technical split:

1. Hoist what can be decided or proven ahead of time.
2. Keep truly dynamic behavior explicit in Zig.
3. Use Lean only where proof work removes runtime branches or discharges
   blocking obligations.

That gives Doe two intended properties relative to general-purpose WebGPU
runtimes:

- less recurring runtime work on hot paths
- smaller, more auditable implementation boundaries

Scope boundary:

- Doe has two core roadmap prongs: Chromium-family WebGPU replacement and
  Doppler -> Doe -> Cerebras retargeting.
- Dawn and Tint are the incumbent runtime/compiler baselines.
- The Doppler Program Bundle is the source identity for the Cerebras prong;
  Doe does not compile arbitrary JavaScript or raw model files.
- Package, native, embedded, and server-side JavaScript lanes are evidence
  ladders, not the final product ceiling.
- Chromium/browser replacement claims only promote from browser-lane artifacts
  that pass compatibility, trace, correctness, and comparability gates.
- Cerebras claims only promote from Program Bundle, lowering, transcript,
  simulator, or hardware receipts with intact identity links.

## Why this exists

Industrial WebGPU stacks pay recurring CPU-side cost from:

- repeated validation
- abstraction layering
- runtime policy branching
- process and bridge overhead in some deployment shapes

Those costs matter most on small, frequent GPU workloads where dispatch,
submission, and setup overhead dominate.

## Operating model

Doe is self-contained:

- the runtime is implemented in Zig
- policy lives in config and schema-backed artifacts
- proof work lives in Lean
- benchmarking, traces, and gates provide the evidence surface

Current Lean theorem inventory is tracked in
`pipeline/lean/artifacts/proven-conditions.json`; `pipeline/lean/README.md`
describes the proof categories and integration boundary.

Dawn, Tint, and wgpu are comparison baselines, not runtime dependencies.

That matters for how Doe should be evaluated. The immediate question is not
"has Doe replaced the browser runtime?" or "has Doe run the full model on
Cerebras hardware?" The immediate question is whether each evidence lane closes
a concrete gap toward one of the two roadmap prongs: compiler quality against
Tint, runtime behavior against Dawn, browser compatibility at the
`navigator.gpu` seam, Doppler Program Bundle ingest, TSIR/HostPlan/CSL
lowering, transcript parity, and diagnostic receipts that explain failures
instead of hiding them behind fallback.

## Verification stance

Formal methods are a tool for shrinking runtime logic, not a substitute for
sandboxing or deployment boundaries.

Doe supports two broad verification profiles:

1. Ahead-of-time verified inputs
   Lean proves selected invariants offline, and Zig executes the resulting
   specialized path.
2. Dynamic runtime verification
   Zig keeps the necessary runtime checks for untrusted or late-bound inputs.

The rule is Zig first, then prove away branches when the proof work is worth
it.

## Evidence standard

Doe only treats performance claims as real when they are backed by:

- matched workload contracts
- explicit comparability and claimability status
- reproducible run metadata
- traceable benchmark artifacts

Narrative claims without those artifacts are not part of the project contract.

## What success looks like

For v0, success is trend-based rather than slogan-based:

- lower hot-path overhead on targeted workloads
- deterministic replay and traceability
- explicit unsupported behavior instead of silent fallback
- improving CTS and benchmark evidence
- proof coverage only where it deletes meaningful runtime logic
- browser-lane progress that keeps the Chromium fork delta small and WebGPU
  focused
- Doppler -> Cerebras progress that keeps Program Bundle identity, lowering
  identity, transcript parity, and hardware promotion receipts linked

## Related docs

- [`problems-addressed.md`](./problems-addressed.md) for specific practitioner
  pain points and how Doe handles them
- [`architecture.md`](./architecture.md) for system surfaces
- [`chromium-webgpu-task-list.md`](./chromium-webgpu-task-list.md) for the
  Dawn/Tint/Chromium task list
- [`cerebras.md`](./cerebras.md) for the Doppler -> Doe -> Cerebras lane front
  door
- [`doppler-ingest.md`](./doppler-ingest.md) for the Doe-owned Program Bundle
  ingest boundary
- [`performance-strategy.md`](./performance-strategy.md) for Dawn comparison
  methodology

## Non-goals

Doe is not trying to:

- replace browser/process sandbox policy with theorem proving
- claim Doe is already the browser runtime standard
- fork Chromium broadly outside WebGPU runtime integration boundaries
- treat package wrappers, browser shims, and native runtime lanes as one surface
- claim wins from non-comparable benchmark runs
- hide policy or fallback behavior in undocumented runtime branches
