# Runtime ownership decision contract

This document defines how Doe decides whether an application needs the owned
Doe runtime. It is an implementation and promotion contract for the strategy in
[`thesis.md`](thesis.md), not a separate product strategy.

## Governing hypothesis

Runtime ownership is a hypothesis to prove, not a default source of product
credit.

Doe may provide value through two separable surfaces:

- **DoeProof**: workload identity, execution policy, independent oracles,
  receipts, replay, comparison, and release admission;
- **DoeRuntime**: the owned compiler, runtime, backend, lifecycle, scheduling,
  memory, cache, synchronization, and readback implementation.

An application should use DoeRuntime only when a controlled comparison proves
that owning execution supplies durable application value unavailable from a
pinned incumbent, DoeProof around that incumbent, or a bounded incumbent patch.
If DoeProof supplies the value without DoeRuntime, that is a valid Doe product
result and a rejection of runtime ownership for that application.

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

The next admitted experiment is the Doppler local-AI package path, and only for
`persistent-performance-control`. The admission receipt at
[`../reports/benchmarks/amd-vulkan/20260815T171507Z/gemma64-no-dispatch-prewarm-attribution.json`](../reports/benchmarks/amd-vulkan/20260815T171507Z/gemma64-no-dispatch-prewarm-attribution.json)
records a comparable 16-sample AMD Vulkan control in which Doe retains an
11.81% p50 and 16.30% p95 workload-wall advantage over prepared Node WebGPU
after Doe's native dispatch-binding prewarm is explicitly disabled. This is a
mechanism antecedent, not application credit: promotion still requires an
unchanged, oracle-bound Doppler workload through the complete `I0/I1/W0/D0`
contract, with a public-API incumbent optimization control if one is available.

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
- `D0` demonstrates a durable advantage over pinned Chromium/Dawn plus DoeProof
  under the same browser evidence contract.

Browser launch by itself is integration evidence, not application value.

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

The first portfolio objective is a small set of promoted applications on the
primary Apple Metal and AMD Vulkan tuples. Each must have clean installation,
effective provider identity, independent output validation, lifecycle coverage,
the required comparison lanes, and one material DoeRuntime or DoeProof
advantage.

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
