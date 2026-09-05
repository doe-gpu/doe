# Doe strategy: make GPU programs ordinary software

Build the independent GPU compiler and runtime that makes useful computation
easy to create, cheap to repeat, and portable across supported hardware.

Agents and human developers should be able to create a simulation or image
analysis, accelerate it, inspect failures, and publish the working computation
without becoming GPU systems engineers. DoeRuntime supplies execution. DoeProof
supplies impartial evaluation. Neither Doppler adoption nor a new browser is a
prerequisite. This document owns strategy; component charters constrain
implementation and artifacts establish current results.

Run this as one execution-ownership program. First qualify the same retained
`doe-gpu` artifact in Node, Bun, and Electron, with explicit provider selection,
shader and output identity, physical adapter and driver identity, fallback state,
and lifecycle. Native embedding uses the same runtime and earns its own host
evidence. Next grow declared DoePlan execution, then qualify frozen external
applications, promote transferable corrections, and expand embedding channels
only after application wins. Resource allocation and portfolio bounds live in
[`doe-product-strategy.json`](../config/doe-product-strategy.json).

## Own the executable program

The proposed primitive is a reusable GPU program: shaders, dependencies,
resource requirements, permitted input variations, and executable plans.
Optimize allocations, pipeline preparation, transfers, command construction,
synchronization, and repeated submission as well as kernels. Retain useful
state and rebuild only affected assumptions.

Safe reuse is the central invention to earn. Shape, binding, shader, driver, or
device changes must invalidate affected state. Removing a check without proving
its precondition is a correctness bug. Begin with explicitly declared fixed-shape
compute, retain deterministic Zig guards, and eliminate work through Lean only
when current proof artifacts discharge the actual preconditions. Keep ordinary
execution available where reuse is unsuitable.

The WGSL compiler, native backends, resource contracts, and declarative plan
executor are foundations. Their existence does not establish a complete program
compiler. The initial additive API and its limits live in
[reusable compute programs](reusable-compute-programs.md).

## Enter through compatibility and earn reuse

Make `doe-gpu` straightforward to try in controlled Node, Bun, Electron, and
native applications. Preserve familiar WebGPU operations and existing WGSL.
Offer repeated computation through an optional declared-program interface.
Replacing a provider cannot eliminate arbitrary JavaScript orchestration that
an application continues to execute.

Each external application compares the strongest incumbent, ordinary Doe, and
prepared DoePlan. Complete useful-operation latency owns the application result;
kernel timing helps diagnose it. Retain cold initialization, preparation, first
execution, repeated tails, CPU and GPU work, memory, allocations, submissions,
teardown, and recovery. Missing measurements remain missing acceptance evidence.

The promise is the same useful computation with less repeated work, smaller
resource demands, and clearer failures. Compatibility substitution and explicit
program integration are different treatments: freeze and disclose each one,
and give incumbent controls equivalent persistent pipelines, bindings, batching,
and caches. An interface alone is not an ownership win if the same optimization
works equally well above an incumbent.

Prepared workflows already exist in
[CUDA Graphs](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/cuda-graphs.html),
and IREE combines scheduling with execution compilation. Doe must differentiate
through WebGPU integration, deployment simplicity, safe reuse, and measured
application outcomes; graph execution is not a Doe invention.

Ordinary browser imports still use browser-owned WebGPU. Browser replacement
requires its own integration, artifact, and acceptance evidence.

## Make corrections transferable

Preserve relationships from original WGSL through IR and backend programs to
execution. Make failures reproducible and effects inspectable. A contributor
should supply a small reproduction and comparison without understanding the
entire runtime.

```text
application failure or measured repeated work
-> minimized source and frozen independent oracle
-> general compiler transformation, resource policy, or backend correction
-> permanent regression and physical evaluation
-> transfer to an unrelated program
-> maintained release gate
```

DoeLab owns this failure-to-correction process. Its next product-level test is
whether accumulated corrections make subsequent applications easier to support,
not whether the regression archive grows. Keep source, interfaces, and
reproduction tools open. Compound development momentum, maintained integrations,
and implementation knowledge through useful results.

## Demonstrate a newly practical application

Start with a non-Doppler scientific or image-processing application that repeats
multistage computation on physical AMD Vulkan. Reproduce the mechanism on Apple
Metal and apply it to another application.

Before tuning, freeze source, inputs, independent numerical requirements,
hardware and driver, fallback policy, lifecycle obligations, timing scopes,
memory accounting, and a meaningful application outcome. Identity hashes bind
bytes; numerical comparisons establish acceptable results.

Compare against competently configured Dawn and wgpu with persistent pipelines,
batching, and caches. Report preparation, cold startup, repeated latency and CPU
cost, peak memory, cancellation, recovery, and when preparation is recovered.
Keep raw samples, tails, failures, and structural work. Distinguish process RSS
and requested buffer bytes from peak GPU memory. Disclose host and effective
readback differences rather than presenting them as runtime speed.

Cross a predeclared useful boundary: a missed interactive deadline, an analysis
memory limit, or unacceptable repeated CPU cost. Numerical parity alone does
not establish that crossing. A transferred correctness fix does not establish
a transferred performance breakthrough. Preserve losses and audit implausibly
large wins before accepting them.

Repository-owned applications can prove a mechanism. External voluntary
adoption and retention require separate evidence from the application's owner.
Receipts, internal benchmarks, sibling integrations, and paid qualification do
not establish adoption. Revenue is not required for the first proof.

## Ownership and independent controls

DoeRuntime is primary. DoeProof remains useful around the strongest eligible
incumbent and cannot select a favorable execution provider. Doppler may supply
a workload or become a user; it receives no qualification preference.

Preserve I0, I1, W0, D0, and credible eligible P0 under the governed
[runtime ownership decision](runtime-ownership-decision.md). An unchanged
application measures provider substitution. An explicit program integration
measures the disclosed application/runtime treatment under identical useful
work. Each freezes the strongest control; neither inherits the other's result.

Priorities remain correctness, operational reliability, compatibility, material
end-to-end value, simple installation, and useful diagnostics and replay.
Receipts cannot compensate for incorrect, unstable, incompatible, or slower work.

## Focus and founder responsibilities

Compiler/runtime ownership covers transformations, reusable plans, invalidation,
resource lifecycle, and backend execution. Application/evaluation ownership
covers integration, packaging, independent controls, diagnostics, and reproducible
tests. Both own the frozen application outcome and transfer test.

Exclude browser construction, Flutter replacement, peer networks, distributed
training, and universal accelerator support from the first demonstration. Dynamic
shapes follow explicit fixed-shape assumptions and verified invalidation.

Later, embedding partners may distribute the same runtime through frameworks,
applications, or browser distributions. Fawn remains separately gated. Existing
A/B/C/D and K0 browser laws retain their meaning; browser construction is not a
dependency. Accelerator work retains separate hardware admission and cannot
broaden the initial matrix through simulator evidence.

## Acquisition hypothesis

An acquirer would buy an execution advantage, its engineering team, development
momentum, and an ecosystem that depends on it. Open code can be licensed;
ownership must add difficult implementation knowledge and maintained integration
capacity that licensing or sponsorship does not supply.

AMD's Nod.ai acquisition is a precedent for interest in compiler expertise and
optimized deployment, not evidence of Doe's valuation. Buyer interest and
valuation remain hypotheses requiring independent evidence.

## Strategy execution map

- [GOALS.md](../GOALS.md) owns mission and durable goals.
- [CATSCAN.md](../CATSCAN.md) and child charters own component authority.
- [Reusable compute programs](reusable-compute-programs.md) owns initial API,
  invalidation, reproduction, and limitations.
- [Developer wedge](node-bun-developer-wedge.md) owns package integration and
  downstream promotion.
- [Product strategy contract](product-strategy-contract.md) maps strategy into
  `config/doe-product-strategy.json`.
- [Performance](performance-strategy.md), [workloads](workload-system.md), and
  [process](process.md) own measurement, evidence, and stage law.
- [Ecosystem](ecosystem.md), `config/ecosystem-registry.json`, and
  `reports/ecosystem/` own external evaluation and adoption state.
- [Support matrix](doe-support-matrix.md) and `reports/claim-index.json` own
  promoted support and public claim eligibility.
- [Browser lane](browser-lane.md) owns the separate browser evidence path.

Artifacts own current outcomes. Strategy prose does not promote an
implementation, benchmark, package, browser, or adoption claim.
