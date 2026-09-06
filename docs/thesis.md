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

The immediate engineering focus is a smaller, clearer, cheaper Zig core. Give
each semantic decision one owner, make resource acquisition and release
complete, and remove unnecessary allocation, repeated analysis, and command
preparation. Qualification verifies these improvements. Use compile-time
programming for facts known at build time; resolve physical device and driver
facts at initialization when their lifetime permits. Shared algorithms must
reduce real work without hiding backend-specific responsibilities. Preserve
characterizing tests and check execution cost, generated code size, and build
cost before accepting a structural optimization.

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

## Proposed user journeys

These journeys describe intended user outcomes, not current support or release
commitments. Begin with provider compatibility, repeated computation, and
transferable corrections. Broader integrations follow demonstrated application
wins and earn separate physical qualification under the existing strategy
contract.

### Replace a WebGPU provider without rewriting the application

A developer selects `doe-gpu` in Node, Bun, or Electron while retaining the
application and WGSL. Compare clean installation, startup, memory, complete
operation latency, and resource release using the same retained package.
Success requires correct output, unchanged validation, explicit capabilities,
and no hidden fallback. A declared program rejects unsupported requirements
before execution. Ordinary WebGPU calls reject unsupported operations before
their dependent GPU work; provider substitution cannot predict future
JavaScript calls. Electron main and renderer integrations qualify separately.

### Keep repeated computation fast and interactive

A photographer adjusts filters or a researcher advances a simulation while
Doe retains buffers and prepared commands. Input changes preserve unaffected
resources, and simulation steps preserve declared state. Cancellation,
transactional updates, cleanup, and reopening have predictable outcomes.
Success means useful responsiveness or faster accepted iterations against
independent numerical checks, with stable memory over prolonged sessions.
Account for initial preparation and final cleanup as well as repetition.

### Fix shader and driver failures once

A contributor reproduces a failing shader on the affected device and follows
source diagnostics through compiler transformations and backend execution.
A narrowly scoped correction or workaround must repair the original program,
preserve unrelated regressions, and transfer to other programs. Keep allocation
failure and cleanup ownership explicit, and avoid unnecessary work on unaffected
devices. Device-specific conditions remain attached to their qualification.

### Ship local AI across desktop hardware

An application team embeds the same runtime through WebGPU, its C interface,
or a separately qualified ONNX Runtime integration for offline search, image
inspection, or inference. Qualify Linux, macOS, and Windows independently.
Success combines acceptable output quality, a smaller deployment burden,
predictable resources, explicit unsupported operations, and reproducible
upgrades without a separate user-installed shader toolchain. A proposed
integration does not expand the current support matrix.

### Coordinate competing workloads across workstation GPUs

A scientist uses an agent to run independent jobs across integrated and
discrete GPUs while retaining interactive responsiveness. This conditional
extension schedules bounded submissions, enforces declared budgets, and
accounts for every required transfer. It must improve accepted batch completion
or responsiveness over the strongest eligible single-device control after
scheduling and copying costs. It assumes neither shared memory nor kernel
preemption nor authority over unrelated applications.

### Accelerate existing browsers and application engines

A browser or Flutter engine maintainer integrates Doe beneath an existing
rendering or WebGPU boundary. Users manipulate diagrams, preview video, or run
local analysis within that host. Success means fewer missed frames, fewer
transfers, or lower complete operation cost while preserving visual output,
isolation, external textures, color handling, and surface lifecycle. Each
host integration requires its own artifact and physical evidence; it distributes
the same runtime after the initial application proof.

### Turn new algorithms into optimized GPU programs

A researcher supplies an algorithm and independent reference tests. A coding
agent proposes GPU implementations and hardware optimizations, measures and
checks each candidate before adoption, and retains prior versions. Success
means useful acceleration of unfamiliar work across supported hardware without
handwritten backend code. Changed drivers trigger revalidation, and accepted
improvements must transfer beyond their original benchmark. This extends the
existing correction loop rather than creating a general agent framework.

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
