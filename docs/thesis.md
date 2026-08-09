# Doe strategy

This is Doe's single product-strategy document. It owns the product objective,
priority order, adoption wedge, downstream-application flywheel, commercial
journey, and expansion boundaries. Supporting documents define implementation
contracts and evidence formats; they do not define a separate strategy.

## Objective

Doe should become the receipt-backed local compute plane for autonomous
software and the applications it operates. An agent or application submits a
versioned workload; Doe executes it under an explicit policy, validates the
result, and returns a receipt that explains what actually ran.

The first product surface is deliberately narrower: a fast, reliable WebGPU
provider for controlled Node, Bun, Electron, and CI workloads. Those surfaces
are the entry point because the application or operator can select the
provider. The long-term identity is verifiable execution, not a general agent
framework, browser automation framework, or universal Dawn replacement.

The defensible claim is bounded:

> Doe executed this named workload correctly and reliably under the declared
> policy, on the declared runtime, hardware, and backend, with a replayable
> receipt; where measured, its end-to-end result is better than the declared
> baseline.

The product promise is equally concrete:

> Give an agent or application a supported local GPU workload and get the same
> correct result, explicit execution identity, visible fallback state, and a
> replayable receipt. On selected tuples, get fewer operational failures or
> materially better end-to-end performance.

Doe expands only after real applications depend on that passing surface.

## Product object

The durable Doe product object is a verifiable execution:

```text
agent or application intent
-> versioned workload and inputs
-> explicit execution policy
-> selected Doe/provider/backend
-> independent output oracle
-> receipt and replay material
```

The workload contract, not an agent protocol, is the stable interface. It
binds the program or model, inputs, executor, policy, output, runtime,
hardware, fallback state, and timing. Node, Bun, Electron, native processes,
headless Chromium, and later controlled GPU workers can be different executor
surfaces beneath the same workload and receipt law.

Doe does not own planning, browser navigation, model selection, prompts, or
general agent orchestration. It makes local compute observable and admissible
for the software that performs those jobs.

## Doe-first operating model

Doe is the product driver. Other projects and external systems are useful when
they make Doe more useful, more provable, or easier to adopt; they do not
silently become Doe's product roadmap.

| Surface | Role in a Doe-first strategy |
| --- | --- |
| Doe runtime/compiler | Product, execution contract, provider, receipt, and release authority |
| Doppler | Collaborator and workload source for local inference, model artifacts, and hybrid-routing examples |
| Dream | Composition and workflow reference application that exercises Doe as a compute tool |
| Columbo/Valera | Design-partner workflow and buyer proof; a Doe customer/use case, not Doe's identity |
| Reploid/Poolday | Browser-agent and receipt-backed distributed-compute proof surface; separate product ownership |
| Chromium/Fawn | Browser host and integration target; Doe first owns the GPU execution seam |
| Cerebras/CSL | Accelerator retargeting proof and specialized execution target |
| Dawn, wgpu, browser WebGPU, MLX, llama.cpp, ONNX Runtime | Incumbents, compatibility baselines, collaborators, or competitors depending on the test |
| External applications | Design partners, workload examples, regression sources, and prospective customers |

The rule is simple: a sibling product may demonstrate a Doe capability, supply
a workload, or become a customer. Its roadmap does not replace Doe's roadmap.
An external project may be a baseline or competitor without becoming a Doe
dependency. Every promoted result must still identify what Doe itself executed.

## Doe-first tracks

The strategy has one driver and several bounded tracks:

1. **Core runtime:** source-preserving WGSL lowering, native execution,
   explicit Metal/Vulkan/D3D12 selection, typed failure, and receipts.
2. **Physical proof:** real applications and named workloads validate output,
   reliability, dispatch structure, fallback state, and end-to-end value.
3. **AI and agent workloads:** inference, embeddings, ranking, image/audio/
   document processing, vector operations, scientific kernels, and agent tool
   calls all use the same workload, oracle, policy, and receipt contract.
4. **Browser substrate:** integrate Doe beneath Chromium's WebGPU seam first;
   later test canvas, effects, media, compositor-adjacent, and other GPU-heavy
   pieces only when a real contract proves Doe adds value. Browser policy,
   layout, networking, security, accessibility, and navigation remain browser
   responsibilities.
5. **Accelerator retargeting:** use TSIR, HostPlan, CSL, and Cerebras as a
   Doe-led portability and proof track, with separate hardware claims.
6. **Execution control plane:** expose inspect, run, verify, compare, and
   replay through CLI, JavaScript, CI, and thin agent/browser adapters. Doe
   owns the execution contract; it does not become an agent framework.

Track status is evidence-driven: active implementation, physical proof,
candidate, diagnostic, archived, or external-owned. An idea cannot enter the
active Doe roadmap merely because a sibling document describes it.

### Idea ledger

This compact ledger keeps named visions from becoming orphaned. The strategy
narrative stays here; implementation and evidence stay in the linked sources.

| ID | Idea | State | What it means now |
| --- | --- | --- | --- |
| `DOE-01` | Fawn agent browser | `diagnostic` | Doe-led Chromium WebGPU seam; browser-wide agent orchestration is outside Doe. |
| `DOE-02` | DoeKernel accelerator scheduler | `candidate` | Queue/resource contracts and prototypes; no browser-wide scheduler claim. |
| `DOE-03` | DoeVM portable compute layer | `diagnostic` | WGSL/IR/TSIR/HostPlan/CSL direction; not yet a universal VM. |
| `DOE-04` | DoeProof execution evidence | `active` | Workload, oracle, receipt, replay, and qualification trunk. |
| `DOE-05` | DoeHypervisor agent isolation | `horizon` | Possible accelerator capability policy; OS/browser security remains external. |
| `DOE-06` | Intent-to-capability web | `external-owned` | WebMCP/site/agent protocols supply workloads; Doe executes their compute edges. |
| `DOE-07` | DoeMind private local AI | `candidate` | Node/Bun/Electron workload wedge; browser-wide personal memory is not current Doe scope. |
| `DOE-08` | DoeCanvas generative rendering | `archived` | Track B rendering modules remain historical until a real unifying workload reopens them. |
| `DOE-09` | DoeForge autonomous software validation | `candidate` | Agent-driven browser/CI validation using Doe receipts and comparison lanes. |
| `DOE-10` | Multiverse/counterfactual execution | `horizon` | Possible branch-comparison workload; browser state forking is external. |
| `DOE-11` | DoeMesh heterogeneous fabric | `horizon` | Local multi-adapter direction; remote/wafer scheduling is not a product claim. |
| `DOE-12` | DoeExchange machine economy | `horizon` | No Doe owner, buyer, settlement, or authority evidence. |

States are deliberately separate from technical maturity and commercial value.
Promote an idea only by linking a contract, implementation, physical or buyer
result, and a concrete next gate. Rename ideas without creating new IDs.

## Platform analogy

The long-term analogy is the JVM, not Java: a portable execution layer
specialized for heterogeneous AI, ML, and agent workloads.

| JVM ecosystem | Doe platform |
| --- | --- |
| Source and bytecode | Agent-authored application, model, WGSL, or versioned workload |
| JVM and JIT backends | Doe runtime and lowering to Metal, Vulkan, D3D12, WebGPU, CSL, and later accelerators |
| Class and artifact loading | Exact model, shader, and program artifact loading by hash |
| Runtime and security policy | Backend, fallback, memory, privacy, and capability policy |
| Stack traces and profilers | Structured traces, timing, diagnostics, and first-failure boundaries |
| Write once, run anywhere | Define once, execute verifiably across declared compute surfaces |

Doe adds what ordinary VM analogies do not guarantee: an independent output
oracle, physical hardware identity, fallback decisions, replay material, and a
hash-bound execution receipt. “Compute VM” is the platform vision; the current
product claim remains the narrower supported WebGPU provider and workload
matrix described below.

Agents sit above Doe. They decide what computation is needed; Doe proves what
actually ran.

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

The initial product is the `doe-gpu` provider for controlled Node, Bun,
applicable Electron, and CI compute environments. The first likely users are
teams shipping local inference, embeddings, search, image, or other GPU
compute through JavaScript runtimes. Doe deliberately supports a narrow,
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

This creates compounding defensibility. Doe accumulates maintained application
dependencies, hardware evidence, regression history, runtime policy, and
explainable execution knowledge. Individual features can be reproduced; the
governed body of real-application behavior and evidence is harder to reproduce.

## Adoption and commercial journey

The Doe-first journey is:

```text
Doe proof workload -> adopter -> design partner -> supported integration
-> release dependency -> paid runtime/evidence relationship
```

This journey is not a registry state machine. Relationship hypotheses,
engagement status, and evidence maturity remain independent so a technically
capable peer can still be a valuable adopter or design partner, and a measured
project is not automatically outreach-ready.

Projects first keep Doe because it improves something operational: regression
reproduction, runtime identity, cross-driver comparison, explicit fallback,
incident diagnosis, or measured performance. The first commercial buyer is
likely a local-AI, browser-AI, developer-platform, or release-infrastructure
team rather than an individual JavaScript developer.

The scrappy land motion is to run one real application workload against the
incumbent and Doe, make the output and execution receipt useful to the team,
and turn the passing workload into a CI or release gate. Dependence grows when
release policy, diagnostics, and replay consume Doe artifacts. Paid work then
centers on runtime integration, supported hardware and workload matrices,
execution policy, evidence maintenance, incident support, and performance
tuning.

Sibling products provide low-cost entry points, not strategic ownership:

- Doppler can supply a local-AI workload and model artifact.
- Dream can provide a composed workflow that makes the result legible.
- Columbo/Valera can serve as a demanding private-document design partner.
- Reploid/Poolday can exercise browser-agent participation and receipt flows.
- Cerebras can test Doe's retargeting beyond commodity GPUs.

Doe can land directly with platform, QA, release, browser, or AI teams through
shadow validation. If a sibling product succeeds, it proves a Doe capability
and creates a reference customer; it does not make Doe merely an internal
upsell.

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

The browser path is the eventual host for browser-operated software and
agents. Doe's browser strategy is piecewise GPU replacement: begin at the
WebGPU/Dawn implementation seam, then earn adjacent GPU-heavy browser work
through separate correctness and compatibility evidence. The objective is to
move more deterministic, parallel work onto accelerators and reduce CPU
orchestration where that improves real workloads; it is not to rewrite
Chromium's policy or user-facing browser architecture.

A controlled headless or headful Chromium artifact must prove forced-Doe
execution,
fallback policy, browser compatibility, reliability, installation, and release
identity before browser claims are made. A browser or package wrapper alone is
insufficient.

Controlled GPU worker fleets are another later surface: a worker can advertise
its runtime, backend, adapter, driver, limits, and policy capabilities, while a
submitted workload declares what it requires. This is an execution and
admission surface, not a new workload model.

Neither path inherits promotion from Node/Bun evidence. Each must pass its own
compatibility, correctness, reliability, installation, and performance gates.
Browser users cannot select the implementation beneath `navigator.gpu`, so
browser adoption requires a real browser integration and artifact rather than
an npm wrapper. Cross-accelerator portability requires hardware evidence, not
simulator results.

Doe does not initially pursue:

- universal Dawn replacement;
- arbitrary npm WebGPU compatibility;
- a general-purpose agent SDK, MCP server, or browser automation product;
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
- [`workload-system.md`](workload-system.md) defines the versioned workload,
  executor, oracle, and receipt contract that carries the strategy across
  execution surfaces.
- [`process.md`](process.md) defines repository stage and gate law.
- [`browser-lane.md`](browser-lane.md) routes the future Chromium execution
  surface without making it current package evidence.
- [`doe-support-matrix.md`](doe-support-matrix.md) defines promoted support
  tuples.
- `config/ecosystem-registry.json` owns current actors and evaluation order.
- `reports/ecosystem/` owns reviewed downstream results.
- `reports/claim-index.json` owns eligible public measured claims.

Changing the objective, priority order, wedge, flywheel, commercial journey,
or expansion boundaries requires changing this document. Current measurements
and actor status belong only in their machine-owned artifacts.
