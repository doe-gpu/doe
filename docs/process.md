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
- Quirk selector changes preserve scope membership, profile filtering, ranking,
  first-input ties, match counts, and proof/action decisions. Characterize both
  builders against retained decisions and exercise allocation failure before
  measuring preparation. A selector microbenchmark does not establish GPU or
  application latency, and compile-time specialization must also account for
  generated code and build cost.
- Toggle registry generation validates the versioned configuration during the
  build and emits immutable runtime entries. Build-parser allocation failures,
  decoded strings, invalid classifications, and generated-value parity remain
  blocking regressions. Runtime lookup preserves case-insensitive first-match
  behavior and explicit unknown results without initialization or fallback
  state. Device matching is still evaluated against the actual runtime profile.
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
- Native pipeline reuse requires exact identity checks and a device-owned
  lifetime. Regression evidence checks actual handles and GPU output across
  independent bindings, creator teardown, shader/layout changes, allocation
  failure, and device isolation. Public resource counters alone do not establish
  native pipeline reuse or reduced useful-operation latency.
- Pipeline and layout hashes only locate candidates. Active, hot, and spilled
  compute cache hits must check complete shader, entry-point, layout, and
  effective subgroup identity. Collision regressions record distinct shaders
  together, replay their exact output, and exercise policy changes and invalid
  entry points without discarding previously owned state.
- Browser claim admission and readiness reporting consume the same receipt
  validators under `bench/browser/release/`; path/hash checks and execution,
  comparison, proof-page, and gallery responsibilities remain separate.
  The Python import boundary protects this package from path mutation while
  preserving the existing directly executed browser gate commands.
- Readiness accepts CTS receipt version 2 only after reconstructing its
  published subset with the canonical receipt builder. Published artifact bytes,
  identity, source hash, and selected query coverage must agree. Version 1 keeps
  its legacy complete-ledger comparison; stale historical receipts cannot
  inherit corrected status. This correction changes no receipt fields or
  release eligibility rules.
- Buffer registry publication must be reserved before initialization can queue
  GPU commands. Replacement drains prior work and preserves the old allocation
  until creation succeeds. Allocation-failure regressions verify that failed
  publication cannot leave unowned initialization work and that retry/readback
  still succeeds.
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
- Shader reflection must publish complete metadata or preserve a typed failure.
  Allocation-failure and capacity regressions distinguish errors from valid empty
  interfaces and verify subsequent valid compilation. Owned compiler diagnostics
  must survive concurrent failed and successful requests. Legacy last-error
  adapters have a per-thread boundary lifetime. Device-owned Metal library
  caching requires independent shader leases, exact source/configuration checks,
  rollback, and teardown tests; physical Metal qualification remains separate
  from allocator and reference-accounting tests.
- Rendering ownership regressions record work, release caller references, write
  inputs after recording, and submit later. Direct and bundled draws must produce
  the accepted pixels through native readback. Releasing a reference is distinct
  from explicit resource destruction. Vertex-format ABI values must match the
  pinned WebGPU header; backend conversion remains local. Render shader-code
  retention must roll back each failed allocation before publishing the pipeline.
  These regressions do not qualify untested attachment, query, or driver-loss
  behavior.
- Strict resident-state updates require an instance- and revision-bound reset
  assessment before replacement allocation. Regressions must cover declined,
  approved, stale and forged approvals, identical-size format changes, version
  downgrade, and failed preparation with the original state still executable.
  Earlier descriptor versions retain their documented update behavior.
- Live-edit applications preflight candidates against frozen independent tests
  outside the process owning active state. Candidate authors supply WGSL, not
  replacement acceptance code. Obsolete candidates, numerical rejection, exact
  reset decisions, activation failure, cancellation, and reopening require
  regressions across the actual package boundary. Continued simulation during
  preflight does not imply asynchronous pipeline creation during activation.
  Bounded submissions and process deadlines do not imply GPU kernel preemption.
- Shader compilation failures preserve the responsible compiler stage, cause,
  and available WGSL source location through native wrappers and
  `getCompilationInfo()`. Regression coverage checks that subsequent compilations
  cannot overwrite a failed module's diagnostic. Graphics translation ownership
  is checked with allocation accounting when a module has multiple entry points
  for the same stage; stage output is emitted once and transferred to the native
  shader module without leaking the original allocation.
- Native addon pass descriptors are checked against the runtime's pinned WebGPU
  header by `packages/doe-gpu/scripts/build-addon.js`; an ABI layout mismatch
  fails the build. Retained-package qualification exercises timestamp pass
  boundaries, repeated query reset/readback, and exact shader output on each
  selected host. Ordered timestamps alone do not establish calibrated GPU time
  or a prepared-program performance claim.
- Retained-package qualification runs the installed first-kernel examples as
  well as governed candidate and lifecycle fixtures. Examples must validate
  their output and release the device; their library identity must match the
  lifecycle run. The qualifier source and host outputs are retained with the
  package archives.
- Vulkan query results must use the versioned nanosecond contract before any
  GPU consumer or readback. The production conversion shader is compared with
  an independent integer oracle, and physical query intervals are bounded by
  an independent host clock. Receipt version 3 distinguishes normalized Doe
  results from historical native-tick receipts; old evidence keeps its units.
- Compute descriptor version 2 adds explicit invocation/program buffer lifetimes;
  native contract version 2 also accepts historical version 1 declarations.
  Receipt version 4 records GPU state provenance separately from known byte
  hashes. The physical program regression must cover omitted-input initialization,
  persistent state, writable inputs, same-device output leases, stale references,
  transactional updates, cancellation, and no-output-readback execution. A
  cancelled submitted resident computation cannot silently continue. These are
  correctness checks; transfer and timing advantages require matched application
  controls and separate evidence admission.
- Resident application comparisons require a separately frozen sequence oracle.
  Fixture version 2 declares initialize-once inputs and program-lifetime buffers;
  every provider uses the same schedule. Evaluation version 4 retains warmup and
  lifecycle invocations so their state generations and numerical results can be
  checked before admitting later samples. Reuploading, clearing, resetting state,
  skipping a generation, or replacing a sequence oracle with its initial result
  fails the evidence gate. Failed numerical outputs and receipts remain retained.
- Vulkan compute and descriptor cache transitions retain the active owner if a
  cache allocation fails. An allocation-fault regression must preserve the old
  handles and allow a later successful insertion and activation. Hashes only
  locate cache candidates: descriptor reuse must also match complete bindings
  and native allocation generations. Physical regressions cover collisions,
  spill, buffer aliases, resource replacement, and orphaned image views.
  Prepared programs reject changed resources before native submission. These
  internal identities preserve the public descriptor and receipt contracts.
- Program close must release native bindings and pipelines as well as buffers.
  Resource-retention regressions keep closed program objects reachable, repeat
  preparation and execution on the same device, and distinguish driver-reported
  allocation totals from residency and peak memory. Destroyed-buffer descriptor
  retirement must preserve unrelated bindings and compatible pipelines. Tests
  also close each recording mode after explicit device destruction; native
  resource references must keep required backend cleanup valid.
  Linux retained-package qualification executes the DRM regression in every
  controlled host, covering timestamp scratch allocations and labeled queues.
- Native command lifetime tests release caller-owned compute state and copy
  resources before deferred use. Recording must preserve those references
  through finish and submission, release abandoned state, and unwind failed
  fused construction. Compute passes and command buffers retain the encoder or
  device needed for cleanup. Explicit destruction remains a separate invalidation
  boundary; this does not admit automatic garbage collection of other objects.
  Fused compute constructors reserve command/reference storage before retaining
  dependencies and publish only after successful construction. Allocation-fault
  tests cover the command-buffer object, list growth after earlier commands,
  aliased copy buffers, abandoned builders, and allocator ownership after finish.
  Native error scopes preserve allocation versus validation failures. These are
  repairs to existing native entrypoints; no public fields or trace schemas change.
  Direct C execution in `runtime/zig/tests/native_recorded_compute.c` must check
  single and batched constructor outputs after caller release. Its library hash
  must match the retained package. The addon's ordinary encoding helper is a
  different path and cannot stand in for this native-constructor check.
  Native-direct package tests also reject duplicate and consumed submissions,
  verify writable mapping copy-back and read-only mapping isolation, and require
  mapped-range detachment on unmap. Run the same test in every qualified host.
- Program receipt version 5 overlaps queue completion with readback mapping and
  waits for both. Failure and cancellation tests must preserve ownership until
  both settle, including either callback order and a rejected mapping. Mapping
  belongs to `submitWait`; `readback` covers host copy, decoding, and unmap.
  Earlier receipt versions retain sequential completion semantics. Evaluation
  rejects mixed schedules before computing comparison rows; all providers use
  the same completion treatment.
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
- Native coverage matrix version 2 requires artifact hashes and real execution
  provenance. Schema examples, renamed examples without an execution chain,
  wrong backends, failed/skipped native work, changed binaries, and missing or
  inconsistent traces cannot establish coverage. The matrix gate validates
  native trace replay and execution counts; it does not confer performance or
  package release admission. Regenerate version 1 sample-based rows from
  physical receipts before marking them covered.
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
- Mixed report globs use the registered explicit kind-to-schema mapping;
  unknown kinds fail before body validation. See
  [schema registry migration](config-schema-enforcement.md#schema-target-registry-migration).
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

Compute arithmetic changes follow the build policy in
`config/spirv-compute-arithmetic-policy.json`. Validate its registered schema,
typed IR, allocation failures, operand evaluation order, and original frozen
application oracles on physical hardware. Retain source, library, and target
artifact identities. A passing compiler suite or a numerically failing incumbent
does not qualify an application comparison. Policy migration and target scope
are documented in [`shader-compiler-architecture.md`](shader-compiler-architecture.md).

Retained-package application evaluation binds the installed package to a passed
Node/Bun/Electron qualification. Archive hashes, installed files, loaded native
library identity, and common executor source are blocking checks. A workspace
library run cannot substitute for that installation evidence. Evaluation
artifact migration is documented in
[`reusable-compute-programs.md`](reusable-compute-programs.md).
Portable qualification records resolve archive and evidence filenames against
their own retained directory. Relocation preserves hashes; it cannot rewrite
provenance or accept escaping paths. Verification checks every recorded input.

Application policies explicitly select host GPU activity observation. When
`gpuActivity=reject-observed-linux-drm`, measured runs require hash-bound raw
DRM observations and fail admission on observed foreign activity or lost counter
continuity. The matrix gate recomputes this check and enforces common policy
identity. Boundary observations do not establish exclusive device access;
isolated-host qualification remains necessary. Numerical audits and historical
policies retain their existing contracts. Migration and observation limits are
documented in [`reusable-compute-programs.md`](reusable-compute-programs.md).

Color-attachment preservation uses the native-addon ownership regression with
adjacent direct/bundled draws, an empty load pass, deferred submission, and
released caller references. The WebGPU input contract and trace schema are
unchanged; the correction carries the existing load semantics through the
internal render command. Native architecture checks, Zig regressions, and
same-package controlled-host qualification remain required. This evidence does
not qualify depth/stencil, store/discard, resolve, or render-query behavior.

Depth ownership extends the same native-addon regression with near/far geometry,
later load passes, read-only depth, empty depth clears, depth readback, and
released caller references. Vulkan uses the caller's retained attachment and the same parent
allocation identity check used by descriptors. Existing WebGPU fields flow
through internal command snapshots; public descriptor and trace schemas do not
change. Stencil operations, depth-only passes, store/discard, multisampling,
and physical non-Vulkan execution remain separately qualified behavior.

Bounded WGSL candidate jobs use `bench/cli.py program candidate`. Admission
requires the independently pinned acceptance job, unchanged reference/input
hashes, valid declared resource budgets, exact qualified package bytes, every
numerical oracle, native execution identities, and completed cleanup. Timings
cannot rescue a failed oracle. Candidate acceptance applies only to the frozen
job's criteria and remains diagnostic; promotion still follows the normal
blocking gates and physical backend requirements. An environment change forces
fresh execution; unchanged identity also reruns acceptance. Additive job and
receipt contracts and migration are documented in
[`reusable-compute-programs.md`](reusable-compute-programs.md#bounded-candidate-jobs).

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
