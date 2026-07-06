# Doe docs index

Grouped pointer to every doc under `docs/`. Files stay flat by intent
(see commit history if curious about why) — this index is the table of
contents.

For dated, append-only history, see [`docs/status.md`](status.md) and
the shards under [`docs/status/`](status/).

## Project front doors

- [`thesis.md`](thesis.md) — what Doe is and why it exists
- [`architecture.md`](architecture.md) — high-level shape of the runtime + compiler + bench surfaces
- [`process.md`](process.md) — gate modes, blocking vs advisory, release rules
- [`status.md`](status.md) — concise status front door; shard policy under `docs/status/README.md`
- [`problems-addressed.md`](problems-addressed.md) — practitioner pain points the runtime targets
- [`glossary.md`](glossary.md) — terminology used across docs
- [`repo-taxonomy.md`](repo-taxonomy.md) — what lives where; tenant boundaries
- [`internal-tooling.md`](internal-tooling.md) — public vs repo-only tooling boundary
- [`licensing.md`](licensing.md) — license surface and third-party
- [`upgrade-policy.md`](upgrade-policy.md) — version compatibility and deprecation rules

## Core roadmap front doors

Doe's roadmap is two-pronged. Both prongs use source-preserving lowering,
schema-backed contracts, gates, and receipts.

Across those prongs, the main goals collapse into three pillars:

1. source-preserving execution plus multi-backend lowering as program identity
   preservation,
2. the native WebGPU runtime as an independent product/runtime surface, and
3. receipt-backed claims plus compiler/proof discipline as the evidence and
   trust system.

- [`chromium-webgpu-task-list.md`](chromium-webgpu-task-list.md) — Chromium-family
  WebGPU replacement: Doe vs Tint, Doe vs Dawn, and forced-Doe browser work
- [`cerebras.md`](cerebras.md) — Doppler -> Doe -> Cerebras retargeting:
  Program Bundle ingest, TSIR / HostPlan / CSL, simulator and hardware receipts

## Chromium WebGPU tasks

- [`chromium-webgpu-task-list.md`](chromium-webgpu-task-list.md) — canonical
  task list for Doe vs Tint, Doe vs Dawn, and forced-Doe Chromium WebGPU work

## Cerebras lane (Doppler → Doe → Cerebras)

Front door: [`cerebras.md`](cerebras.md). Bundle packer + claim-discipline
gate depend on the bundle and appendix files; do not rename.

- [`cerebras.md`](cerebras.md) — single front door (progress, source code, reproduce, hardware)
- [`cerebras-hardware-runbook.md`](cerebras-hardware-runbook.md) — operator how-to for hardware receipts
- [`cerebras-evidence-bundle.md`](cerebras-evidence-bundle.md) — bundle source (parsed by the prep script)
- [`cerebras-evidence-bundle-pointer.md`](cerebras-evidence-bundle-pointer.md) — auto-generated archive pointer
- [`cerebras-model-ledgers.md`](cerebras-model-ledgers.md) — model acceptance bars and blocker queues
- [`hardware-validation-appendix.md`](hardware-validation-appendix.md) — bundle compatibility and claim-governance appendix

## CSL (Cerebras shader language) layer

- [`csl-architecture.md`](csl-architecture.md) — CSL abstraction stack
- [`csl-quickstart.md`](csl-quickstart.md) — getting started with CSL emit
- [`csl-layer-block-self-check.md`](csl-layer-block-self-check.md) — layer-block self-check protocol

## Compiler / TSIR

- [`tsir-lowering-plan.md`](tsir-lowering-plan.md) — TSIR architecture and lowering plan
- [`shader-compiler-architecture.md`](shader-compiler-architecture.md) — WGSL → backend pipeline
- [`lean-bounds-elimination-design.md`](lean-bounds-elimination-design.md) — Lean-driven proof elimination of runtime branches
- [`doppler-ingest.md`](doppler-ingest.md) — Doppler ingest contract
- [`loop-protocol.md`](loop-protocol.md) — TSIR iteration discipline

## Runtime / packaging

- [`node-bun-developer-wedge.md`](node-bun-developer-wedge.md) — Node/Bun package GTM and benchmark wedge
- [`doe-gpu-node-runtime-scope.md`](doe-gpu-node-runtime-scope.md) — Node runtime scope
- [`package-model.md`](package-model.md) — npm package contract
- [`gpu-math-api-proposal.md`](gpu-math-api-proposal.md) — experimental `doe-gpu`
  math API proposal, examples, coverage, and tradeoffs
- [`apple-metal-runtime-release.md`](apple-metal-runtime-release.md) — Apple Metal runtime bundle
- [`metal-macos-proof-bundle-runbook.md`](metal-macos-proof-bundle-runbook.md) — Metal macOS proof bundle runbook
- [`fawn-fork-maintenance-policy.md`](fawn-fork-maintenance-policy.md) — Fawn (Chromium fork) policy
- [`concurrency-strategy.md`](concurrency-strategy.md) — runtime concurrency model

## Performance + benchmarks

- [`benchmark-taxonomy.md`](benchmark-taxonomy.md) — canonical compare taxonomy
- [`performance-strategy.md`](performance-strategy.md) — performance work approach
- [`doe-support-matrix.md`](doe-support-matrix.md) — platform × surface × runtime support
- [`browser-lane.md`](browser-lane.md) — routing note for browser-lane tasks,
  contracts, and artifacts
- [`numeric-stability.md`](numeric-stability.md) — determinism + numeric stability
- [`claim-discipline.md`](claim-discipline.md) — claim-language rules over benchmark output
