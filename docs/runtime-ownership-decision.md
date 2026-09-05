# Runtime ownership decision contract

This document defines how Doe decides whether an application needs the owned
Doe runtime. It is an implementation and promotion contract for the strategy in
[`thesis.md`](thesis.md), not a separate product strategy.

## Governing hypothesis

Runtime ownership is a hypothesis to prove, not a default source of product
credit.

DoeRuntime is primary and DoeProof is a supporting feature. Their contributions
remain experimentally separable:

- **DoeProof**: workload identity, execution policy, independent oracles,
  receipts, replay, comparison, and release admission;
- **DoeRuntime**: the owned compiler, runtime, backend, lifecycle, scheduling,
  memory, cache, synchronization, and readback implementation.

An application should use DoeRuntime only when a controlled comparison proves
that owning execution supplies durable application value unavailable from a
pinned incumbent, DoeProof around that incumbent, or a bounded incumbent patch.
If DoeProof supplies the value without DoeRuntime, retain that useful feature
result and reject runtime ownership for that application. It does not satisfy
the primary DoeRuntime adoption objective.

## What a governed incumbent can already provide

A fair control must give the incumbent every capability that can be implemented
above its public runtime boundary:

- requested-provider and effective-provider identity where exposed;
- pinned workload, input, program, package, and binary hashes;
- independent output validation;
- process, operation, timing, and memory observations;
- explicit fallback reporting where observable;
- application-level replay;
- dependency and artifact provenance;
- release policy and receipt generation.

These properties alone do not justify DoeRuntime.

## Runtime-ownership properties

Every promoted application must name at least one property that it claims
requires DoeRuntime:

| Property | Required owned-runtime evidence |
| --- | --- |
| Enforcement | Doe rejects prohibited fallback, backend substitution, or unsupported execution before work begins when the governed incumbent cannot enforce the same policy. |
| Failure localization | Doe identifies a lowering, pipeline, command, synchronization, completion, or readback boundary that remains opaque through the incumbent contract. |
| Lifecycle control | Doe measurably improves queue ordering, teardown, device loss, resource ownership, cancellation, concurrency, or process cleanup. |
| Program-identity preservation | Doe binds source through normalized IR, lowering policy, backend artifact, command graph, and executed output where the incumbent cannot expose an equivalent chain. |
| Independent correction | Doe fixes a release-relevant compiler or runtime defect more effectively than waiting for upstream or carrying a bounded incumbent patch. |
| Persistent performance control | Doe improves a user-visible operation through scheduling, cache, memory, synchronization, or lowering control unavailable above the incumbent boundary. |
| Reproducible runtime identity | Doe supplies an exact provider binary and execution contract that a pinned incumbent distribution cannot match. |

“More inspectable” is not a sufficient ownership property. The contract must
name the incumbent limitation, the application consequence, and the receipt
field or measurement that adjudicates it.

## Required comparison lanes

The optional reusable-program interface is a separate declared application
treatment. Freeze its shaders, inputs, outputs, and integration diff before
comparison and give controls persistent pipelines, bindings, batching, and
caches. A program integration does not establish unchanged-provider substitution;
an internal mechanism demonstration does not establish voluntary adoption.
The same ownership lanes below apply to the frozen treatment.

Every ownership candidate uses the same versioned workload, inputs, semantic
oracle, hardware tuple, process policy, synchronization, readback, cache state,
sample policy, and user-visible timing scope across four required lanes:

| Lane | Construction | Question |
| --- | --- | --- |
| `I0` | Unmodified ambient incumbent | What does the application receive from its ordinary environment? |
| `I1` | Exact pinned and packaged incumbent binary | Does distribution control remove ambient-version and dependency uncertainty? |
| `W0` | `I1` plus DoeProof policy, oracle, receipt, replay, and release machinery | Is the evidence/control layer sufficient without owning execution? |
| `D0` | DoeRuntime plus the same DoeProof machinery | What application value is uniquely created by the owned runtime? |

When the claimed advantage is independent correction, add one conditional
control:

| Lane | Construction | Question |
| --- | --- | --- |
| `P0` | `W0` plus the smallest reviewable incumbent patch that corrects the defect | Is a bounded upstream/fork patch cheaper and equally effective? |

The incumbent lanes must not be deliberately weakened. If an identity,
fallback, lifecycle, trace, or packaging property is available through a
documented incumbent interface, the governed control must use it.

## Predeclared adjudication

Before execution, the application contract must freeze:

- the ownership-required property;
- the exact incumbent limitation;
- workload, source, inputs, and oracle identity;
- supported operating system, architecture, adapter, driver, and backend;
- process, cache, synchronization, completion, and readback policy;
- correctness or numerical-tolerance rule;
- reliability trials and failure injections;
- selected user-visible operation and statistical decision rule;
- the material advantage required from `D0` over `W0` and, when used, `P0`;
- additional source, packaging, compatibility, security, and maintenance cost;
- the evidence paths and release consequence.

A post-run choice of a favorable metric is not admissible. Internal phase
timing may explain a result but cannot replace the frozen user-visible outcome.

## Operational trust contract

Doe does not claim abstract or universal trust. A receipt is evidence for
specific properties; it is not itself trust.

| Property | Required evidence |
| --- | --- |
| Provider identity | Requested and effective provider, backend, adapter, driver, and binary identities agree with policy. |
| No hidden fallback | Every attempted and selected path is recorded; prohibited fallback fails with its original typed cause. |
| Correct output | An independent semantic oracle passes exactly or under a predeclared numerical tolerance. |
| Reproducibility | Clean-process replay reproduces the declared semantic result and required deterministic artifacts. |
| Reliability | Crash, hang, timeout, cancellation, teardown, concurrency, memory-growth, and device-loss gates pass. |
| Dependency closure | Required binaries, libraries, drivers, data, commands, and runtime artifacts are identified. |
| Supply-chain integrity | Packages are hash-bound, provenance is retained, signatures are verified where required, and packaging is reproducible under its declared contract. |
| Upgrade predictability | Compatibility policy, pinned downstream gates, and typed migrations cover promoted consumers. |
| API compatibility | The exercised WebGPU surface and applicable conformance scope are declared; unsupported behavior fails explicitly. |
| Security | The threat model, native boundary, dependency policy, isolation assumptions, and vulnerability-response ownership are declared. |

Exact byte identity and tolerance-bounded semantic equivalence are different
oracle classes. The workload contract must select one before execution; provider
agreement alone is not an independent oracle.

## Ownership cost ledger

A runtime win is not automatically a product win. Every promotion decision must
record the additional obligations created by DoeRuntime:

- owned source and backend surface;
- WebGPU compatibility and conformance debt;
- platform, adapter, and driver coverage;
- native security and supply-chain exposure;
- release, packaging, and clean-install work;
- upstream behavior and specification ingestion;
- application-specific exceptions;
- ongoing regression and support obligations.

The ownership decision compares the material application advantage with these
obligations. A narrow incumbent patch or governed wrapper wins when it produces
the same application outcome with a smaller durable obligation.

## Decision branches

The terminal decision is mechanical:

- **Promote DoeRuntime** when `D0` passes correctness and reliability, beats
  `W0` and any required `P0` on the predeclared material outcome, and its
  ownership cost is accepted.
- **Promote DoeProof with the incumbent** when `W0` closes the application gap.
- **Carry or upstream a bounded patch** when `P0` closes the gap with less
  durable cost than DoeRuntime.
- **Retain diagnostic evidence** when the result explains a failure but does
  not satisfy promotion.
- **Retire the application lane** when none of the governed constructions
  creates material application value.

Gains from DoeProof and DoeRuntime must remain attributable. A `D0` receipt may
not assign runtime credit to a property already supplied by `W0`.

## Release portfolio tiers

Applications have four non-interchangeable roles:

| Tier | Release consequence |
| --- | --- |
| Core blocker | A very small, stable application set required by every release on its declared primary tuples. |
| Platform blocker | Required only when a release affects its backend, operating system, architecture, or package tuple. |
| Diagnostic application | Executed regularly and retained as evidence, but cannot block or promote a release. |
| Experimental probe | Discovers compatibility gaps without creating a support commitment. |

Promotion into a blocking tier requires the complete installation, oracle,
replay, lifecycle, resource, support-target, and ownership-attribution contract.
The number of benchmark rows does not determine the tier.

The first three completed application decisions are terminal for their frozen
workloads:

- HoloScript's exact-output matrix does not distinguish `D0` from passing
  `W0`;
- `wgsl-fns` exposes an incumbent failure, but bounded `P0` closes it and
  matches `D0`;
- vGPU does not distinguish `D0` from `W0` on the governed lifecycle outcome.

All three remain diagnostic regression assets and provide no runtime-ownership
credit. Select a new ownership candidate only from a measured property that a
governed incumbent wrapper cannot reproduce; do not weaken or reinterpret a
completed gate.

HoloScript's separate LIF determinism gate reaches the same terminal ownership
decision. The reviewed artifact at
[`../reports/ecosystem/holoscript-snn-webgpu/holoscript-lif-determinism-2026-08-15-diagnostic.json`](../reports/ecosystem/holoscript-snn-webgpu/holoscript-lif-determinism-2026-08-15-diagnostic.json)
shows exact `W0` and `D0` replay plus byte-identical GPU membrane and spike
outputs across the governed incumbent and Doe for all frozen cases. It remains
a valuable cross-provider correctness regression, but it supplies no outcome
that justifies runtime ownership.

The Electron main-process successor for HoloScript is a distinct runtime-host
diagnostic and does not reopen the terminal Node decision. The current-runtime
replay at
[`../reports/ecosystem/holoscript-snn-webgpu/holoscript-electron-main-process-p0-current-runtime-2026-08-16-diagnostic.json`](../reports/ecosystem/holoscript-snn-webgpu/holoscript-electron-main-process-p0-current-runtime-2026-08-16-diagnostic.json)
freshly reconstructs the bounded control and reaches the same terminal result:
the unchanged application passes the exact oracle in all three `D0` processes
and replay, while `I0`, `I1`, and `W0` fail at Electron's prohibition on
external ArrayBuffers. A bounded application upload workaround reaches a native
abort, but a source-built `webgpu@0.3.10` `P0` with a two-file mapped-buffer
ownership correction passes three processes and exact replay. The incumbent
patch therefore closes the application gap and rejects DoeRuntime ownership for
this tuple. The result remains a diagnostic regression and grants no ownership,
application-promotion, performance, release, renderer, Chromium, or browser
credit.

The Gigi generated-WebGPU suite is also terminal for its frozen
independent-correction hypothesis. The reviewed artifact at
[`../reports/ecosystem/electronicarts-gigi/gigi-runtime-ownership-2026-08-16-diagnostic.json`](../reports/ecosystem/electronicarts-gigi/gigi-runtime-ownership-2026-08-16-diagnostic.json)
binds the ambient incumbent, pinned incumbent, governed incumbent, and Doe
lanes plus semantic replay for both governed providers. Every lane retains the
same application outcome, so the incumbent requires no bounded correction and
DoeRuntime receives no ownership credit. The suite remains a diagnostic
compiler/runtime regression asset; its shared oracle failures prevent
promotion or performance interpretation.

The World Labs consumer-execution suite is likewise terminal for its frozen
independent-correction hypothesis. The reviewed artifact at
[`../reports/ecosystem/world-lab-runtime-webgpu/world-lab-runtime-ownership-amd-vulkan-2026-08-16-diagnostic.json`](../reports/ecosystem/world-lab-runtime-webgpu/world-lab-runtime-ownership-amd-vulkan-2026-08-16-diagnostic.json)
binds I0, I1, W0, and D0 across three clean processes per lane. The identical
transparent evidence layer records all dynamic shader attempts, dispatches,
draws, submissions, and exact mapped readbacks. W0 and D0 reproduce one shared
shape, semantic-evidence, and output identity. Because the pinned incumbent
passes directly and under governance, P0 is not authorized and DoeRuntime
receives no ownership credit. The three Doe compiler/runtime repairs remain
valuable permanent regressions; they do not justify owning execution for this
application outcome.

The cpp-ml MNIST graph is terminal for the same frozen independent-correction
hypothesis. The reviewed artifact at
[`../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-runtime-ownership-amd-vulkan-2026-08-16-diagnostic.json`](../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-runtime-ownership-amd-vulkan-2026-08-16-diagnostic.json)
binds `I0`, `I1`, `W0`, and `D0` plus semantic replay for both governed
providers. All 18 source and replay processes pass the staged independent
oracle with one shared output identity. Because `W0` exposes no defect, `P0`
is not authorized; because `D0` does not exceed `W0`, the result grants no
runtime-ownership credit. The application remains a valuable exact
cross-provider regression.

The separate `persistent-performance-control` hypothesis is terminal through
[`../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-persistent-performance-control-amd-vulkan-2026-08-16-diagnostic.json`](../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-persistent-performance-control-amd-vulkan-2026-08-16-diagnostic.json).
Both providers pass 30 cold processes, five warm-up suites, and 100 warm suites
with exact cross-provider semantic identity. Doe is slower at cold and warm
p50, p95, and p99, exceeding the frozen 1.05x maximum-regression boundary at
every percentile. No clean-install performance successor, promotion-scale
stress population, or runtime-ownership claim is authorized for cpp-ml.

The later
[`doe-proof-node` filesystem diagnostic](../reports/ecosystem/electronicarts-cpp-ml-intro/cpp-ml-mnist-doeproof-cli-filesystem-amd-vulkan-2026-08-16-diagnostic.json)
authorizes the public CLI boundary after correcting native compute-binding
truncation. That product-boundary pass is deliberately orthogonal to ownership:
it records `runtimeOwnershipCredit: false` and leaves this terminal decision
unchanged.

The UMAP SGD selected-operation experiment is terminal for its frozen
`persistent-performance-control` hypothesis. The reviewed artifact at
[`../reports/ecosystem/umap-gpu/umap-sgd-governed-benchmark-amd-vulkan-2026-08-16-diagnostic.json`](../reports/ecosystem/umap-gpu/umap-sgd-governed-benchmark-amd-vulkan-2026-08-16-diagnostic.json)
binds deterministic input, exact 192-byte output identities, complete dispatch
shape, physical provider identity, selected-operation timing, and W0/D0
semantic replay. All four lanes pass. Doe improves p95 but records a 0.9705x
W0/D0 speedup at p50, so it misses the predeclared 1.10x requirement at both
percentiles. Cross-provider embedding bytes differ while both remain exact
within provider and pass the semantic oracle. The result is a permanent
floating-output and performance regression; it grants no runtime-ownership,
performance, promotion, or release credit and cannot be rescued by tuning.

The Doppler local-AI package experiment was admitted only for
`persistent-performance-control`. The admission receipt at
[`../reports/benchmarks/amd-vulkan/20260815T171507Z/gemma64-no-dispatch-prewarm-attribution.json`](../reports/benchmarks/amd-vulkan/20260815T171507Z/gemma64-no-dispatch-prewarm-attribution.json)
records a comparable 16-sample AMD Vulkan control in which Doe retains an
11.81% p50 and 16.30% p95 workload-wall advantage over prepared Node WebGPU
after Doe's native dispatch-binding prewarm is explicitly disabled.

The application result at
[`../reports/benchmarks/amd-vulkan/20260815T182649Z/doppler-provider-runtime-ownership-diagnostic.json`](../reports/benchmarks/amd-vulkan/20260815T182649Z/doppler-provider-runtime-ownership-diagnostic.json)
is terminal for that frozen hypothesis. Doe runs the unchanged Doppler workload
correctly and releases its provider cleanly, but it is materially slower than
the governed incumbent on the selected user-visible operation. The synthetic
antecedent therefore does not transfer and supplies no runtime-ownership
credit. The incumbent teardown abort is retained as lifecycle evidence only;
it cannot be repurposed into a lifecycle-control win without a separately
frozen hypothesis, bounded-patch control, and lifecycle acceptance rule.

A later bounded diagnostic found that the package provider was clamping native
Radeon limits to Doe's conservative fallback table. The corrected provider
binds limits and features to the selected physical-device identity and publishes
the queried limits without that ceiling. On the exact bounded one-token case,
the corrected path preserves output identity and reduces prefill from
14,676.65 ms to 175.99 ms while increasing model-load time from 22,180.23 ms to
41,618.68 ms. The receipt is
[`../reports/benchmarks/amd-vulkan/20260815T190434Z/doppler-provider-capability-publication-diagnostic.json`](../reports/benchmarks/amd-vulkan/20260815T190434Z/doppler-provider-capability-publication-diagnostic.json).
This mechanism result does not reopen or reinterpret the prior gate. It may
admit only a new, versioned W0/D0 comparison whose frozen user-visible operation
includes model load, repeated inference, exact output, and teardown.

That new comparison is terminal at
[`../reports/benchmarks/amd-vulkan/20260815T190434Z/doppler-provider-corrected-runtime-result.json`](../reports/benchmarks/amd-vulkan/20260815T190434Z/doppler-provider-corrected-runtime-result.json).
W0 and D0 produce identical output, and Doe releases cleanly. Doe nevertheless
takes 67,683.30 ms versus W0's 50,481.15 ms on the complete session and
5,535.60 ms versus 1,334.69 ms on median timed inference. It misses both frozen
5% requirements, so the corrected Doppler performance family is retired without
tuning. W0's post-release native abort remains lifecycle evidence only.

The separately frozen lifecycle hypothesis is now terminal through
[`../reports/benchmarks/amd-vulkan/20260816T074546Z/doppler-provider-lifecycle-control-diagnostic.json`](../reports/benchmarks/amd-vulkan/20260816T074546Z/doppler-provider-lifecycle-control-diagnostic.json).
Three clean W0 processes complete exact inference and governed release, then
terminate natively through one SIGABRT and two SIGSEGV outcomes. The exact same
pinned incumbent behind the bounded P0 wrapper waits on and destroys four
tracked devices, preserves the W0 output identity, and exits zero in all three
processes. The governed wrapper therefore closes the measured lifecycle gap;
DoeRuntime receives no ownership credit and no larger Doppler lifecycle gate is
authorized. D0 also exits cleanly three times, but its deterministic one-token
output differs from W0/P0 and remains a separate unassigned correctness finding.
The bounded transcript successor at
[`../reports/benchmarks/amd-vulkan/20260816T080140Z/doppler-provider-logit-divergence-diagnostic.json`](../reports/benchmarks/amd-vulkan/20260816T080140Z/doppler-provider-logit-divergence-diagnostic.json)
places that difference in finalized model logits, before sampling. It remains a
correctness-localization task and cannot reopen Doppler runtime ownership.

## Expansion admission

### Fawn and Chromium

Fawn proceeds from diagnostic integration to product promotion only when:

- a named application or adopter requires a browser provider rather than the
  package surface;
- the package surface cannot serve the workload;
- an installable, hash-bound Fawn release candidate exists;
- forced Doe identity and prohibited-fallback rejection pass;
- an unchanged browser application passes its independent oracle and lifecycle
  gates;
- matched A/B/C/D evidence isolates the Fawn shell, DoeRuntime, and Direct
  Protocol contributions under the same browser evidence contract.

Browser launch by itself is integration evidence, not application value. A
passing B-versus-A decision may promote Fawn while rejecting DoeRuntime browser
ownership. C-versus-B owns that runtime decision, and D-versus-C separately owns
the Direct Protocol decision.

### Lean

Lean work proceeds when it removes a runtime branch, discharges a blocking
artifact contract, or eliminates a release-relevant dynamic check. A theorem
without a named runtime, compiler, artifact, or release consumer remains proof
research and does not promote a product surface.

### Cerebras and accelerator retargeting

Cerebras work proceeds when it unlocks a named workload or proves a reusable
lowering, provider, parity, or execution contract. Simulator, smoke, and
hardware evidence retain their separate claim classes. Work without a named
consumer and next admission gate remains quarantined research.

## Product validation boundary

The first portfolio objective is one unchanged external non-Doppler application,
beginning with AMD/Vulkan unless a real customer supplies a stronger tuple.
Apple Metal and Windows D3D12 earn support separately. Each lane needs clean installation,
effective provider identity, independent output validation, lifecycle coverage,
the required comparison lanes, and a material DoeRuntime advantage over W0
and credible eligible P0, followed by voluntary adoption and repeat retention.

Internal promotion proves a supported integration. External product validation
requires at least one application owner to depend on the contract and treat its
gate as release-relevant. A repository-owned harness alone does not prove
adoption.

## Evidence ownership

- Workload and oracle law: [`workload-system.md`](workload-system.md)
- Comparison and timing law: [`performance-strategy.md`](performance-strategy.md)
- Initial package wedge: [`node-bun-developer-wedge.md`](node-bun-developer-wedge.md)
- Application registry and promotion state: [`ecosystem.md`](ecosystem.md)
- Support boundary: [`doe-support-matrix.md`](doe-support-matrix.md)
- Public claim state: `reports/claim-index.json`
- Current runtime status: [`status/runtime-backends-and-bench.md`](status/runtime-backends-and-bench.md)

Mutable results belong in receipts, reports, and machine-owned registries. This
document owns the decision law and must not copy changing benchmark values.
