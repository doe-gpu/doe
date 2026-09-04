# Doe goals

## Mission

DoeRuntime is the primary product in the `doe/` repository: the owned WGSL
compiler, GPU runtime, resources, synchronization, lifecycle, and native
backends. DoeProof is its provider-neutral qualification and evidence feature,
not a separate primary product. Fawn is a secondary browser product and
potential distribution surface for DoeRuntime.

Doe makes local GPU execution explicit, controllable, reproducible, and
reviewable. It accepts a declared workload and policy, executes through an
identified provider and backend, validates the result, and retains evidence of
what actually happened.

## Value

Applications should be able to substitute a governed GPU provider beneath a
supported workload, preserve exact or tolerance-bounded results, reject hidden
fallback, diagnose the first failing boundary, and replay the execution. A
receipt is evidence for those properties; it is not itself correctness, trust,
or application value.

## Durable goals

1. **Governed local execution.** Support a deliberately bounded matrix of real
   application workloads on declared runtimes, platforms, adapters, drivers,
   and backends.
2. **Program-identity preservation.** Bind source and inputs through normalized
   representations, lowering policy, backend artifacts, command graphs,
   outputs, and receipts.
3. **Fail-closed control.** Make provider selection, unsupported capability,
   fallback, lifecycle, synchronization, and failure state explicit.
4. **Independent correctness.** Require a semantic oracle and declared
   exactness class before reliability or performance promotion.
5. **Application-earned ownership.** Own a runtime only where matched controls
   prove value beyond a pinned incumbent, Doe's evidence layer around that
   incumbent, or a bounded incumbent patch.
6. **Compounding operational knowledge.** Turn real failures into normalized
   contracts, minimized reproductions, permanent regressions, and maintained
   release gates.
7. **Bounded expansion.** Extend into browsers, accelerators, and formal
   verification only through separately admitted workloads and evidence.

## Immediate operating objective: independent customer proof

Development serves one externally owned, unchanged, non-Doppler WebGPU
application that voluntarily adopts DoeRuntime because a predeclared
application outcome improves, then retains it across another release or workload.
Begin with AMD/Vulkan unless a real customer supplies a stronger target; every
other platform earns support separately.

Freeze the application, strongest incumbent, WGSL, input, independent oracle,
hardware, driver, fallback policy, lifecycle gates, and material threshold.
Measure I0, I1, W0, D0, and every credible eligible P0 under equivalent work.
DoeProof qualifies both providers impartially; it cannot choose a favorable
provider or alter execution. Preserve negative results. A paid qualification,
receipt, internal benchmark, or Doppler integration is not runtime adoption.
Stop expansion if applications need rewrites or the advantage does not survive
independent repetition.

Fawn remains a separate evidence-gated product experiment. Its repository-owned
work is a complete Linux release archive, isolated forced-Dawn and forced-Doe
verification, one unchanged exact-oracle application, A/B/C/D execution, and K0
execution through Cloudflare Browser Run plus Kitesurf. Unsupported K0 workloads
remain explicit `ineligible` rows and never become synthetic Fawn wins. Fawn is
promotable only when customers value local-private persistent workflows; DoeRuntime
earns browser ownership only when C beats B; Direct Protocol survives only when D
beats C.

The independence test is binding: DoeRuntime must earn its first adoption
without Doppler. DoeProof remains usable around the strongest eligible incumbent
without requiring DoeRuntime. Supporting-feature value must not be counted as
runtime adoption, and collaborating products receive no provider preference.

## Authority

[`docs/thesis.md`](docs/thesis.md) owns current product strategy and adoption
sequence. [`CATSCAN.md`](CATSCAN.md) and its descendants own component
boundaries and invariants. Registries, tests, reports, and receipts own current
status. Neither current code nor narrative measurements override these
authorities.
