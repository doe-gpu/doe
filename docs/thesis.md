# Doe strategy

This is Doe's single product-strategy document. It owns the product objective,
priority order, adoption wedge, downstream-application flywheel, commercial
journey, and expansion boundaries. Supporting documents define implementation
contracts and evidence formats; they do not define a separate strategy.

## Objective

Doe should become the fastest, most reliable WebGPU compute runtime for Node
and Bun on a deliberately narrow supported surface.

The defensible claim is bounded:

> Doe is faster and more reliable than the declared baseline for these named
> workloads, runtime versions, operating systems, adapters, and drivers.

The product promise is equally concrete:

> Drop Doe into a supported Node or Bun GPU application and get the same
> correct result, fewer operational failures, and materially better end-to-end
> performance. The receipt proves the runtime path.

Doe expands only after real applications depend on that passing surface.

## Priority order

1. Correct output.
2. Operational reliability.
3. Compatibility with real applications.
4. Material end-to-end performance.
5. Frictionless installation.
6. Receipts, replay, governance, and support.

Reliability and speed are the admission ticket. Receipts are essential
evidence and an enterprise retention advantage; they do not compensate for an
incompatible, incorrect, unstable, or slower runtime.

## Initial wedge

The initial product is the `doe-gpu` provider for controlled Node, Bun, and
applicable Electron compute environments. Doe deliberately supports a narrow,
declared matrix of applications, workloads, runtimes, operating systems,
architectures, backends, adapters, and drivers.

The first adoption step must be small: install the package, substitute the
provider, run one existing WGSL workload, validate the existing application
result, and receive runtime identity plus an execution receipt. No local Zig
build, hidden fallback, or undocumented environment setup belongs in the
promoted path.

Several deeply supported applications are more valuable than broad API-shaped
coverage that no real downstream project exercises.

## Downstream-application portfolio

Doe must build and maintain a portfolio of real downstream applications whose
correctness, reliability, installation, performance, and receipt contracts can
block Doe releases on their declared hardware matrices.

Every candidate begins as evidence, not as a customer claim. Doe runs the
unchanged workload through the incumbent provider and Doe, using the same
inputs, output oracle, commands, synchronization, readback, and measurement
scope. A useful external result either proves a reproducible advantage or
exposes a concrete runtime failure that Doe can diagnose and fix.

When an application is promoted into the supported portfolio, its contract
must define:

- pinned upstream source, license, and update policy;
- supported runtime, operating-system, adapter, and driver matrix;
- clean installation and provider-substitution path;
- output oracle and tolerance;
- crash, hang, timeout, concurrency, teardown, device-loss, and memory gates;
- cold and warm end-to-end p50, p95, and p99 performance thresholds;
- fallback prohibition and runtime-identity requirements;
- required receipts, diagnostics, and retained evidence.

A diagnostic run is not a promoted release gate. Promotion requires physical
hardware evidence, equivalent work, a passing oracle, repeated clean-process
reliability, and the declared performance decision.

## Product flywheel

```text
external application
-> exposes a real failure or measurable loss
-> generalized runtime or compiler fix
-> permanent focused regression
-> promoted downstream release gate
-> safer release
-> credible adoption
-> supported commercial relationship
```

This is the moat. Doe accumulates maintained application dependencies,
hardware evidence, regression history, runtime policy, and explainable
execution knowledge. Individual features can be reproduced; the governed body
of real-application behavior and evidence is harder to reproduce.

## Adoption and commercial journey

The likely journey is:

```text
validation workload -> adopter -> design partner -> supported integration
```

This journey is not a registry state machine. Relationship hypotheses,
engagement status, and evidence maturity remain independent so a technically
capable peer can still be a valuable adopter or design partner, and a measured
project is not automatically outreach-ready.

Projects first keep Doe because it improves something operational: regression
reproduction, runtime identity, cross-driver comparison, explicit fallback,
incident diagnosis, or measured performance. Dependence grows when CI gates,
release policy, diagnostics, and replay workflows consume Doe artifacts. Paid
work then centers on runtime integration, supported hardware and workload
matrices, execution policy, evidence maintenance, incident support, and
additional governed operators.

Doppler provides a complementary application-led route: it can land a local-AI
feature, while Doe becomes the infrastructure layer when the customer needs
runtime control, replay, numeric stability, audit evidence, or execution-boundary
policy. Doe can also land directly with platform, QA, or release teams through
shadow validation before selected production execution moves onto it.

## Technical advantage

Doe preserves one program identity across source, intermediate
representations, backend binaries, command graphs, execution results, and
receipts. That identity makes correctness and performance claims auditable
across Metal, Vulkan, D3D12, and later execution targets.

The implementation principles are:

- source-preserving lowering;
- explicit provider and backend selection;
- typed unsupported behavior;
- independent output oracles;
- deterministic schemas and artifact hashes;
- no hidden fallback in promoted lanes;
- user-visible operation timing rather than isolated internal phases;
- machine-owned support and claim state.

## Expansion boundaries

Two longer-range paths reuse the same contracts:

- Chromium-family WebGPU integration beneath `navigator.gpu`;
- Doppler Program Bundle to TSIR, HostPlan, CSL, simulator, and Cerebras
  hardware execution.

Neither path inherits promotion from Node/Bun evidence. Each must pass its own
compatibility, correctness, reliability, installation, and performance gates.
Browser users cannot select the implementation beneath `navigator.gpu`, so
browser adoption requires a real browser integration and artifact rather than
an npm wrapper. Cross-accelerator portability requires hardware evidence, not
simulator results.

Doe does not initially pursue:

- universal Dawn replacement;
- arbitrary npm WebGPU compatibility;
- browser replacement inferred from package evidence;
- determinism as an abstract purchasing argument;
- broad speed claims from one workload or machine;
- governance language used to mask runtime gaps.

## Strategy execution map

- [`node-bun-developer-wedge.md`](node-bun-developer-wedge.md) defines the
  package and downstream promotion contract.
- [`ecosystem.md`](ecosystem.md) defines actor scoring, state, and evidence
  routing without inventing a commercial funnel.
- [`performance-strategy.md`](performance-strategy.md) defines measurement and
  comparison requirements.
- [`process.md`](process.md) defines repository stage and gate law.
- [`doe-support-matrix.md`](doe-support-matrix.md) defines promoted support
  tuples.
- `config/ecosystem-registry.json` owns current actors and evaluation order.
- `reports/ecosystem/` owns reviewed downstream results.
- `reports/claim-index.json` owns eligible public measured claims.

Changing the objective, priority order, wedge, flywheel, commercial journey,
or expansion boundaries requires changing this document. Current measurements
and actor status belong only in their machine-owned artifacts.
