# Doe goals

## Mission

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

Development serves one externally operated `I1` to `W0` DoeProof episode
around the customer's incumbent. Completion requires a paid external
qualification, exact incumbent and physical hardware identity, independently
bound application oracle and replay, a blocking release decision authorized by
a production trust anchor, and repeat requalification. `W0` passes and failures
remain immutable evidence and never open `D0` automatically. `D0` is eligible
only after `W0` exposes a customer-relevant limitation, and it must beat both
`W0` and every credible bounded `P0` correction under the unchanged contract.

Fawn remains a separate evidence-gated product experiment. Its repository-owned
work is a complete Linux release archive, isolated forced-Dawn and forced-Doe
verification, one unchanged exact-oracle application, A/B/C/D execution, and K0
execution through Cloudflare Browser Run plus Kitesurf. Unsupported K0 workloads
remain explicit `ineligible` rows and never become synthetic Fawn wins. Fawn is
promotable only when customers value local-private persistent workflows; DoeRuntime
earns browser ownership only when C beats B; Direct Protocol survives only when D
beats C.

The independence test is binding: DoeProof must sell without Doppler. Doppler may
supply workloads, but it is not a prerequisite for DoeProof value or execution.

## Authority

[`docs/thesis.md`](docs/thesis.md) owns current product strategy and adoption
sequence. [`CATSCAN.md`](CATSCAN.md) and its descendants own component
boundaries and invariants. Registries, tests, reports, and receipts own current
status. Neither current code nor narrative measurements override these
authorities.
