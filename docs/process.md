# Doe process law

This is the normative process contract. Exact commands and platform procedures
live in `docs/operator-runbook.md`, `bench/README.md`, topical runbooks, and
executable `--help`. Checked-in schemas and policy assets remain authoritative
for their fields and values.

## Canonical intent contract

Doe does not add a second free-form run-intent field. Executable intent is the
workload tuple:

```text
immutable inputs + oracle + executor + correctness/claim policy + required evidence
```

An `operationKind` may be derived for routing, but it must not duplicate or
override workload policy. Timing is evidence carried by a workload; it does not
make an unverified workload claim-bearing.

Component intent is independently governed by the applicable root-to-target
`CATSCAN.md` chain. Resolve that chain before entering a stage. If work changes
a component boundary, update the affected charter before Gate and regenerate
`docs/component-index.md`. The blocking CATSCAN gate validates structure and
references; semantic alignment remains the handoff and review obligation in
[`component-charters.md`](component-charters.md).

## Stage order

Every promoted change follows this order:

```text
Mine -> Normalize -> Verify -> Bind -> Gate -> Benchmark -> Release
```

1. **Mine** records upstream behavior and immutable provenance.
2. **Normalize** converts mined behavior into strict, versioned Doe contracts.
3. **Verify** proves, guards, or rejects the normalized behavior.
4. **Bind** maps accepted contracts to runtime/compiler implementation points.
5. **Gate** checks schema, correctness, trace, verification, and any
   claim-specific obligations.
6. **Benchmark** measures only workloads that passed the required earlier
   stages.
7. **Release** publishes only evidence-bound artifacts that satisfy the
   declared promotion policy.

A later stage never excuses or overrides an earlier-stage failure. Rejected,
guard-only, diagnostic-only, and incomplete artifacts must remain visibly
classified and cannot be promoted by benchmark results.

## Workload and evidence law

- A workload declares immutable input identity, oracle, executor, policy,
  required artifacts, and evidence extensions.
- Correctness precedes performance interpretation.
- Declared reusable-program evaluations freeze numerical oracles before tuning,
  measure preparation separately, include persistent/batched incumbent controls,
  and test reset, source/shape updates, cancellation, and recovery. Package
  receipts describe submitted work; native journals and independent output
  oracles must substantiate execution. Host command recording does not establish
  reusable GPU command buffers, external adoption, or a performance advantage.
- GPU-recorded program evidence must bind a native preparation event to every
  replay submission, preserve source/backend identities, and validate output
  independently. Interleaved programs, ordinary execution, updates, and device
  destruction exercise retained resource ownership. Evaluation policy selects
  the percentile estimator; changing it cannot reinterpret historical results.
- External declared-program fixtures retain pinned shader and oracle source,
  toolchain, input bytes, and expected outputs before provider audits. The gate
  checks every reference, declared input extent, and complete oracle coverage.
  Exact observables and independent absolute/relative tolerances cannot be
  weakened to a generic numerical comparison. Batched ordinary controls execute
  every adaptation pass used by the prepared program. Fixture execution alone
  does not promote an external application or establish adoption.
- Queue-ordering repairs require a regression with a separate asynchronous
  producer submission and readback submission, plus the original external
  reproduction. Host-visible memory does not waive GPU execution dependencies.
- Native addon pass descriptors are checked against the runtime's pinned WebGPU
  header by `packages/doe-gpu/scripts/build-addon.js`; an ABI layout mismatch
  fails the build. Retained-package qualification exercises timestamp pass
  boundaries, repeated query reset/readback, and exact shader output on each
  selected host. Ordered timestamps alone do not establish calibrated GPU time
  or a prepared-program performance claim.
- Program GPU timing is an explicit evaluation policy. Timestamp pass markers
  must bracket equivalent completion stages, and counter precision must be
  disclosed. The gate recomputes calibrated durations, percentile statistics,
  query readback bytes, and requested allocations. Useful-operation timing
  includes instrumentation; GPU-only intervals cannot replace it.
  Vulkan clock calibration must agree with an independently captured physical
  profile, including adapter identity and compute-queue counter width. The
  policy bounds decimal rounding; an uninitialized nanosecond assumption is
  never a fallback. Pinned incumbent implementation sources must substantiate
  raw-tick versus nanosecond interpretation.
- Readback allocation policy is versioned in
  `config/vulkan-buffer-memory-policy.json`. Cached memory is a preference;
  coherence and supported memory-type requirements remain mandatory. Validate
  the selection regression and physical ordinary/prepared application controls
  before interpreting an allocation-policy change as an improvement.
- Claim-bearing workloads must emit every evidence extension declared by their
  policy. Missing evidence fails closed.
- Focused module tests are valid executor mechanisms when they provide a
  smaller first-failure boundary or unique oracle sensitivity. Remove one only
  after the workload duplicate-removal gate proves equivalent sensitivity.
- Public claims bind to receipts, source/config identities, execution boundary,
  toolchain identity, and comparability status.
- A claim-bearing external-project report must reference a passing preparation
  receipt that binds the same actor, harness, upstream commit, clean checkout,
  physical support target, toolchain, and Doe/provider artifacts. The release
  gate opens and verifies that receipt; a manifest declaration alone is not
  evidence.
- A Fawn browser release candidate must bind a complete archive manifest and a
  passing clean-install check. The check extracts the published archive into a
  fresh temporary directory, borrows no package members, runs the packaged
  browser, and verifies forced Dawn and forced Doe WebGPU execution against the
  packaged artifact hashes. A declared launch receipt without that observation
  cannot enter Release.

## Gate policy and failure precedence

- Schema, correctness, trace, and required verification gates are blocking.
- Claim runs additionally require comparability coherence, structural
  equivalence, timing/sample policy, claimability, and indexed evidence gates
  selected by the claim contract.
- Advisory performance evidence cannot override a blocking failure.
- Unsupported behavior, stale generated artifacts, missing provenance, unknown
  fields, placeholder semantics, and absent proof metadata fail closed.
- Platform-specific lanes may be skipped only when their checked-in policy
  permits that classification; a skip is never positive evidence.
- The first failing obligation is the primary failure. Later failures may add
  diagnostics but must not conceal it.

## Verification precedence

Use the strongest required mechanism declared by the contract:

1. `lean_required` must have current hash-bound Lean evidence.
2. `lean_preferred` uses current Lean evidence when available and otherwise the
   explicit governed guard/rejection path.
3. `guard_only` retains the runtime guard and its tests.

Proofs may eliminate runtime branches only when the extracted registry binds
the theorem, classification, mirrored runtime symbol, and source hash. A proof
artifact with missing or stale metadata is invalid.

## Compiler completeness

A lowering step emits either a valid typed semantic value or a typed rejection
with source/node location and reason. Semantic placeholders are forbidden.
Artifacts containing rejections are diagnostic-only and cannot enter code
generation, parity promotion, or claim-bearing workloads.

## Refactor law

Behavior-preserving refactors follow this evidence sequence:

```text
capture characterization workload
-> extract neutral contract
-> move implementation
-> preserve an exercised compatibility facade
-> compare semantic digest, trace, oracle, and receipt
-> remove the facade only after consumers migrate
```

If a refactor intentionally tightens or changes a contract, its receipt must
classify that delta separately from preserved cases. Compatibility facades
remain only while an exercised consumer requires them.

## Debug and trace law

- Diagnostics observe execution; they do not silently select different
  semantics.
- Traces use stable operation codes, monotonic ordering, hash chaining, and
  explicit artifact identity.
- Diagnostic and claim-bearing outputs remain partitioned.
- Replay validates metadata and the complete trace chain before interpreting
  results.

## Policy values and generated guidance

- Domain thresholds, ABI values, retry counts, sizes, and timing policy live in
  named constants or versioned config, with one source of truth.
- Generated guides and views are checked against their canonical registries.
- Current commands belong in the operator runbook or generated help, not in
  this process law.
- Toolchain upgrades follow `docs/upgrade-policy.md` and must regenerate and
  revalidate affected provenance-bound artifacts.
