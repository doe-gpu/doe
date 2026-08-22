# Doe architecture

## System surfaces

Doe has three user-facing/runtime-adjacent surfaces and two supporting layers.

1. `runtime/zig`
   The core Doe runtime: WGSL pipeline, backend execution, runtime artifacts,
   and shared-library outputs.
2. `packages/doe-gpu`
   The JavaScript package surface for Node.js, Bun, Deno, and browser-facing
   wrappers.
3. `browser/chromium`
   The active Fawn/Chromium product lane: integration contracts, release
   packaging, clean-install verification, browser probes, and evidence gates.
4. `bench`
   Compare harnesses, gates, and evidence workflows.
5. `pipeline/*` plus `config/*`
   Quirk mining, proof artifacts, trace/replay contracts, schemas, and policy.

These surfaces are related, but they are not interchangeable.

They also sit at different maturity levels. Dawn remains the WebGPU runtime
used in Chromium and much of the browser ecosystem. Doe's native/package lane
has physical evidence; Fawn is an active first-class product target whose
current browser evidence remains diagnostic.

## Strategic decomposition

Doe's docs should read as one dominance program against the Chromium WebGPU
incumbent stack, not as isolated feature tracks. The decomposition is:

1. **Program identity preservation**
   Source-preserving execution and multi-backend lowering are the same concern:
   preserving source/program identity from input through every lowered artifact
   and execution receipt. WGSL, Doe IR, TSIR, HostPlan, CSL, MSL, SPIR-V,
   DXIL/HLSL, command graphs, and trace receipts must stay linked by explicit
   hashes and contracts.
2. **Independent native runtime surface**
   The native WebGPU runtime path remains its own product surface:
   `doe-zig-runtime`, `libwebgpu_doe`, the JavaScript package bindings, and
   native/drop-in lanes. Chromium integration should prove this runtime in a
   browser process model; it should not collapse the runtime product into a
   browser fork.
3. **Evidence and trust discipline**
   Receipt-backed claims and compiler/proof discipline are one trust system.
   A claim against Tint, Dawn, or Chromium is valid only when the relevant
   compiler evidence, runtime trace, browser diagnostic, proof artifact, or
   benchmark report satisfies the gate for that surface.

The shared execution unit for that trust system is a correctness-bearing
workload. Pure transforms, native runtimes, browsers, and comparisons are
executor adapters beneath one contract. The core ledger stays executor-neutral
and binds specialized evidence through typed extensions; see
[`workload-system.md`](workload-system.md).

## Architectural law: Hexagonal inside, vertically integrated outside

1. **Inside the Zig Runtime:** Decoupled, contract-governed, and acyclic
   (`src/contracts/` -> `src/backend/ports/` -> `src/app/` -> leaf backends).
   No browser-specific globals, no direct cross-backend imports.
2. **Outside the Zig Runtime:** Vertically integrated product composition
   (`Fawn` browser shell + `DoeRuntime` compiler/executor + `DoeLab` learning
   loop + `DoeProof` governance).
3. **Cross-Layer Optimization:** Governed through explicit contracts
   (`WorkloadProfile`, `SpecializationPolicy`, `PromotionReceipt`), never
   through hidden runtime heuristics or implicit environment checks.

## Product boundary rules

The important boundary distinctions are:

- `runtime/zig` is the real runtime implementation
- `runtime/bridge/onnxruntime-ep` is a repo-only integration seam for a future Doe-backed ONNX Runtime plugin EP
- `doe-gpu` is the package surface over that runtime
- `doe-gpu/browser` is a browser wrapper, not the Doe runtime running inside the browser
- `browser/chromium` is the active Fawn browser-runtime lane, not the current package wrapper
- `bench` measures surfaces; it is not itself a product surface

Current scope:

- Dawn is the comparison baseline
- Doe runs in Node.js, Bun, Deno, drop-in, and embedded/native lanes
- a Doe-backed ONNX Runtime plugin EP is a repo-only experimental integration seam
- browser `navigator.gpu` replacement is an explicit independently gated product lane, not the current package claim

That separation is deliberate. It keeps package ergonomics, runtime behavior,
and browser integration from getting blurred together in docs or benchmarks.

## Core module flow

At a high level, Doe works like this:

1. `pipeline/upstream_intelligence` and `pipeline/agent`
   Preserve versioned Gerrit and issue evidence, produce constrained review
   packets, and independently mine checked-out source for quirk/workaround
   signals.
2. `config`
   Holds schemas, policies, workload contracts, and versioned control data.
3. `pipeline/lean`
   Formalizes selected obligations and emits proof artifacts when enabled.
4. `runtime/zig`
   Consumes config and optional proof artifacts, then executes the runtime on
   Metal, Vulkan, or D3D12.
5. `bench` and `pipeline/trace`
   Verify correctness, comparability, replayability, and claimability from
   emitted artifacts.

The current Lean theorem inventory is recorded in
`pipeline/lean/artifacts/proven-conditions.json`; architecture docs should
refer to that artifact rather than restating counts.

## Execution model

Doe is designed around explicit runtime behavior:

- backend selection is policy/config driven
- strict lanes do not silently fallback
- unsupported capabilities fail with typed, actionable errors
- hot-path behavior stays in Zig unless it can be hoisted out by proof/config

Current native backend identities are:

- `doe_metal`
- `doe_vulkan`
- `doe_d3d12`
- `dawn_delegate` as the Dawn-comparison lane

## Verification boundary

Doe supports two broad modes:

1. Ahead-of-time verified execution
   Selected invariants are proven offline and used to remove runtime work.
2. Runtime-checked execution
   Zig keeps the necessary dynamic checks for untrusted inputs.

The design rule is:

1. implement deterministic behavior in Zig first
2. measure it
3. move conditions into proof/config only when that lets Doe delete runtime
   branches safely

## Browser lane split

There are two distinct browser-related paths:

1. `packages/doe-gpu/browser`
   A JS shim that forwards to the browser's own WebGPU objects. No Doe Zig
   runtime executes there.
2. `browser/chromium`
   The Track A lane that aims to make browser `navigator.gpu` run on Doe
   instead of Dawn.

Those paths answer different questions and should not be described as the same
thing.

They also sit at different maturity levels. The browser shim is a present
compatibility surface. The Fawn/Chromium lane is an active integration and
release target against the Dawn-based runtime browsers ship today, but it
remains diagnostic until a complete archive passes isolated clean install,
forced-provider identity, an unchanged application oracle, and lifecycle gates.

## Build and evidence outputs

A useful Doe build/run can emit:

- runtime artifact(s)
- run metadata
- trace or trace-meta artifacts
- a self-checking source-to-IR-to-backend execution identity receipt
- benchmark reports
- optional proof artifacts and hashes

The artifact chain matters as much as the code. Doe treats claims as valid only
when they are tied back to those emitted contracts.

For native Vulkan, the execution-identity receipt composes the runtime's shader
artifact manifest with trace metadata and the workload oracle. It verifies the
exact WGSL, semantic state, IR, SPIR-V bytes, manifest identity, backend lane,
no-fallback state, dispatch count, and output digest. This is stronger than the
public JavaScript observer because it reaches the runtime-owned lowering
artifact; it remains narrower than driver- or operating-system-level tracing.

Package applications can opt into a separate native Vulkan identity journal
with `DOE_PROGRAM_IDENTITY_TRACE_PATH`. The public observer records the
application-visible source, command shape, synchronization, readback, and
output. The native journal independently binds exact WGSL and SPIR-V digests to
encoded compute dispatches and direct render draws. Compute completion is bound
to a later outer queue-submission row. Direct Vulkan render completion is bound
to `internal_submit_and_wait_succeeded`, emitted only after the render backend's
own submit-and-wait returns. A reviewed gate must join those layers explicitly;
neither layer is treated as proof of the other, and the journal is not a driver
trace or an output oracle.

## Related docs

- [`docs/problems-addressed.md`](./problems-addressed.md) for practitioner pain points and how Doe handles them
- [`docs/thesis.md`](./thesis.md) for project rationale
- [`docs/process.md`](./process.md) for stage order and gates
- [`docs/csl-architecture.md`](./csl-architecture.md) for the CSL-specific abstraction boundary and host-plan lowering model
- [`docs/tsir-lowering-plan.md`](./tsir-lowering-plan.md) for the
  parity-oracle-first WGSL -> TSIR -> multi-backend lowering architecture
  (Phase A compiler surface landed; live status in
  [`docs/status/tsir.md`](./status/tsir.md))
- [`docs/numeric-stability.md`](./numeric-stability.md) for the numeric-stability integration path, claim boundary, demo bar, semantic envelope, and live runtime contract roadmap
- [`pipeline/lean/README.md`](../pipeline/lean/README.md) for Lean proof categories and the artifact boundary
- [`bench/README.md`](../bench/README.md) for compare and claim workflows
- [`docs/workload-system.md`](./workload-system.md) for the shared workload,
  executor, oracle, and ledger contract
- [`docs/runtime-hexagonal-architecture-plan.md`](./runtime-hexagonal-architecture-plan.md) for the target hexagonal (ports-and-adapters) architecture and migration plan for the Zig runtime
- [`runtime/zig/README.md`](../runtime/zig/README.md) for runtime details
- [`browser/chromium/README.md`](../browser/chromium/README.md) for the Chromium lane
