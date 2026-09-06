# Runtime architecture audit

This is the current classification of Doe's non-test Zig surfaces. It is an
architecture review, not a claim that every line is promoted product code.
The [generated source map](../../runtime/zig/src/README.md) derives responsibility
labels and named build views from
[source-layout.json](../../runtime/zig/source-layout.json). Directory names
and enforced imports do not establish optimal organization or hardware support.
The import fence and source-layout gates are the structural authority; this
page records the lifecycle interpretation and follow-up decisions. The target
structural roadmap lives in [`../runtime-hexagonal-architecture-plan.md`](../runtime-hexagonal-architecture-plan.md).

## Source-edit build measurements

Build measurement now distinguishes clean compilation, a no-change rebuild, and
config-declared edits to a leaf backend function, shared contract, compiler
stage, and public entry point. The tool copies source into a private snapshot;
it restores and rebuilds the baseline between edits. Raw build time, per-build
process memory, source fragments, and resulting artifact sizes live in
`bench/out/shader-ownership/20260906-owned-diagnostics/build-measurements-v3.json`.
The memory field is the largest process RSS reported by `wait4`, not simultaneous
memory summed across the build tree. These behavior-preserving source edits
measure edit-to-build work, not the complexity of every possible feature change.

Receipt version 3 replaces the misleading `incrementalCompile` name with
`noChangeCompile` and separate `editCompiles`. Historical version 2 receipts keep
their original no-change meaning. Reproduce with
`python3 runtime/zig/tools/capture_build_measurements.py`; the scenarios are
owned by `config/zig-build-measurements.json` and receipt fields by its report
schema. Generated architecture reports continue to reject a mismatched source
fingerprint. This work does not change runtime behavior or import boundaries.

## Current quirk preparation boundary

Quirk preparation retains the existing bucket and allocator interfaces while
sharing selection between the profile-filtered and prefiltered builders. The
current selector uses bounded bucket state; stable ranking, profile admission,
proof decisions, and command aliases retain their existing meaning. Retained
failure, parity, allocation, and preparation-cost evidence lives in
[`quirk selection`](../../bench/out/quirk-selection/20260906-direct-accumulation/README.md).
This CPU preparation evidence does not promote backend or application performance.

Toggle classifications now use immutable build-generated storage from the
existing configuration. Lookup has no parser arena, persistent allocation,
initialization lock, or readiness flag. Actual device matching remains a runtime
decision. The decoded-string failure reproduction, generated-value parity,
allocation-failure tests, and build-tier evidence are retained in
[`static toggle registry`](../../bench/out/quirk-selection/20260906-static-toggle-registry/README.md).

## Current ABI approval boundary

Recomposition ABI approval is symbol-scoped. The reviewed PCI-identity
extension is recorded in
`runtime/zig/reports/recomposition/abi-contract-approval.json`; it is an
additive optional internal extension with explicit zero/unavailable semantics
and does not establish hardware attestation, cross-backend driver
normalization, performance, or physical-device qualification. The semantic
verifier rejects category-wide ABI approval, removed symbols, extra exports,
stale predecessor receipts, and source-digest drift.

Commit-bound semantic capture remains separate from physical qualification.
AMD Vulkan, Fawn browser, and Windows D3D12 promotion still require their own
clean-checkout physical receipts against the frozen release candidate.

## Current Python sharding advisories

The canonical Zig size policy remains blocking through
`runtime/zig/source-layout.json`. The repository-level file-size gate now uses
that contract directly and treats Python files above the review threshold as
tracked architecture advisories. It ignores generated output, virtual
environments, vendored trees, and package installations rather than counting
them as Doe source.

The current advisory owners and next semantic split targets are:

- Browser-release evidence owner: receipt validation now belongs to
  `bench/browser/release/`, shared by claim admission and readiness reporting.
  Execution, comparison, proof-page, gallery, and artifact checks have narrow
  owners; the existing command and receipt contracts remain unchanged.
  Next split targets are claim admission, proof-surface inspection,
  runtime-frontier bundle validation, and their fixture-heavy tests. This covers
  `bench/gates/claim_index_browser_release.py`,
  `bench/gates/claim_index_browser_release_proof.py`,
  `bench/tools/check_browser_published_proof_surface.py`,
  `bench/tools/check_browser_release_artifact_bundle.py`, and the matching
  browser release/frontier tests.
- Replacement-readiness owner: split readiness report construction and tests
  into backend, package, browser, CTS, ecosystem, and claim-summary sections.
  This covers `bench/tools/build_dawn_replacement_readiness_report.py` and
  `bench/tests/test_dawn_replacement_readiness_report.py`.
- Benchmark orchestration owner: separate argument families from profile and
  gate assembly in `bench/runners/blocking_gates_args.py`; separate Tint
  compilation setup, execution, comparison, and receipt emission in
  `bench/native-compare/compare_doe_vs_tint_compilation.py` and
  `bench/tools/check_tint_compiler_frontier_bundle.py`.
- Ecosystem and Node evidence owner: split registry parsing, contract
  validation, and receipt projection in `bench/lib/ecosystem_registry.py`;
  split the Node executor tests by adapter identity, package execution,
  readback, and failure taxonomy.
- Cerebras runner owner: continue the already tracked splits of manifest
  probing, dense-tile materialization, transcript execution, layer-block
  smoke, scheduler readiness, and their fixture-heavy tests by launch,
  artifact, receipt, and timeout responsibility.

The live gate output is the source of truth for which files currently trigger
these advisories. A follow-up closes only when the named responsibility has
moved to a focused module and the original file falls below the review signal;
line-only sharding is not sufficient.

## Current canonicalization pass

The latest source-layout evidence incorporates two boundary corrections:

- `src/compiler/wgsl/mod.zig` is now a compatibility facade. Analysis,
  diagnostics, binding reflection, override application, and per-target
  translation live under `src/compiler/wgsl/pipeline/`; shipped backend and
  native consumers import only the stage and target they execute.
- Runtime translation now has separate compute, graphics/reflection, and
  shared-metadata owners under `src/compiler/wgsl/runtime/`.
  `runtime_compile.zig` retains the exercised public aggregation surface while
  shipped consumers import the narrow owner they execute; its integration
  workloads live under `runtime/zig/tests/wgsl/`.
- Vulkan kernel path resolution, SPIR-V file loading, WGSL fallback
  compilation, and the owned kernel-source cache now live in
  `src/backend/vulkan/vk_shader_source.zig`; compute pipeline and descriptor
  lifetime management no longer owns repository-path or compiler concerns.
  Descriptor preparation and validation live in `vk_descriptors.zig`;
  `vk_descriptor_identity.zig` owns exact native resource snapshots. Pipeline
  creation and active/hot/spilled cache ownership remain separate responsibilities.
- Metal kernel dispatch no longer writes CSL and HostPlan files under
  `bench/out/` or silently ignores generation failures. HostPlan creation stays
  in the explicit spatial, plan-executor, and benchmark lanes; the shared
  receipt fields remain available for those paths.
- WGSL translation integration tests and their shared fixture now live under
  `runtime/zig/tests/wgsl/`, rather than making test support reachable from the
  production compiler graph.

See `runtime/zig/reports/architecture/reachability-views.json` for the measured
change to the shipped runtime graph. CSL target modules are now confined to the
compiler/TSIR/spatial toolchain view rather than arriving through runtime
facade imports.

The same evidence also incorporates a behavior-preserving consolidation of
repeated Zig implementation details:

- execution result construction and telemetry snapshots are owned by
  `src/runtime/execution_receipt.zig`;
- plan command counting and declared-count validation are owned by
  `src/plan/plan_validation.zig`;
- shared WGSL IR queries, proof-oriented builtin and stride resolution, and
  stage-IO and texture classification are owned by narrow modules next to the
  IR, while semantic type-syntax parsing remains with frontend consumers;
- TSIR frontend passes share one WGSL-to-TSIR scalar-kind mapping instead of
  carrying per-pass copies;
- CSL bounded text writing, storage declaration emission, pointer exports, and
  storage-export naming are shared by the target emitters instead of copied
  into each operation module;
- CSL compile-section serialization and extraction are one round-trip-tested
  contract shared by core and host compile-source emission;
- CSL and DXIL external compiler lanes share one toolchain discovery,
  allocation-ownership, label, and diagnostic-selection contract;
- target-neutral C-family operator spellings are shared by HLSL and MSL, while
  the MSL literal-cast policy remains target-owned in its maps module;
- uncached SPIR-V result-instruction assembly is owned by the shared SPIR-V
  emitter layer, with builtin and texture emitters retaining narrow wrappers;
- TSIR global-base lookup delegates to the canonical WGSL IR query rather than
  carrying frontend-specific copies;
- TSIR semantic metadata serialization is shared across the CSL, WebGPU, and
  text-skeleton emitters, and its source is included in the affected emitter
  identity digests.

The emitted contracts and runtime behavior are unchanged. Source-backed
emitter identities change intentionally because the shared serializer is now
part of their transitive implementation. Current module decisions,
reachability, and duplicate-declaration evidence are in
`runtime/zig/reports/architecture/`.

## Current reachability correction

`runtime/zig/source-layout.json` now defines named reachability views for the
shipped native/package runtime, drop-in compatibility, module-incubation and
evidence tools, compiler/TSIR/spatial toolchains, and test-only compatibility.
The aggregate production-root graph remains the blocking import/reachability
gate. The named views are classification evidence and do not weaken that gate.

See
`runtime/zig/reports/architecture/reachability-views.json` for current module
and line coverage, overlap, facade-only files, and any files absent from every
view. This is the version-3 source-layout contract; version 2 reports do not
carry named-view evidence.

The first corrected pass removed disconnected `core` and `full` aggregation
barrels plus the unconsumed full-module render-runtime chain. Their only
source import path was the broad barrel policy itself; shipped, toolchain,
integration, benchmark, and test roots did not consume them. Test-only legacy
type aggregators and surface contracts remain explicit in their own view rather
than being presented as shipped runtime.

## Verdict

The runtime is layered and its declared import topology is currently green:

- `zig build import-fence` passes.
- `zig build source-layout` passes.
- No dependency, cycle, reachability, or cohesive-module exceptions are
  currently recorded in `runtime/zig/source-layout.json`.

That proves the boundaries are enforceable. It does not prove that every
boundary is the smallest or best reuse boundary. The main remaining risks are
known legacy contract paths, broad layer permissions, platform-specific
parallel implementations, and diagnostic/future modules living under
production-shaped roots.

The 2026-08-22 execution migration also made the central runtime boundary
physical rather than documentary:

- all canonical `Command` values become one read-only borrowed
  `PreparedOperation` before backend execution, while retained work must own a
  deep `OwnedPreparedOperation` snapshot;
- the application runner dispatches compute, transfer, render, resource,
  surface, lifecycle, and spatial domains only through narrow ports;
- the production CLI, plan executor, output oracle, and Metal correctness
  benches construct `ExecutionSession` in composition and pass a borrowed
  `PortBundle` into runtime;
- the former `backend/backend_runtime.zig` owner is deleted;
- evidence observers receive the same prepared operation and result as the
  runner and cannot return an error or select a provider;
- unsupported spatial execution returns an explicit unsupported report rather
  than synthetic success.

Metal, Vulkan, D3D12, and delegate providers now instantiate their narrow port
vtables directly through a compile-time provider adapter. The provider-driver
contract has no broad `executeCommand` escape hatch. The runtime catch-all
`BackendIface`, `BackendVTable`, `BackendRuntime`, and backend registry are
deleted. `composition/backend_factory.zig` is the sole ordinary module allowed
to import multiple physical providers, and it owns selection, lifetime, and
destruction without exposing a semantic execution facade. Drop-in FFI
provider-integration roots are enumerated separately by the import fence rather
than receiving a blanket `backend/` exemption. Metal and Vulkan pipeline-cache
configuration, handles, device binding, and telemetry are provider-instance
state rather than process-global session state.

The 2026-08-23 consumer audit also deleted fourteen package-reexported
incubation modules: unused application normalization/validation/scheduling
facades, unused composition inbound facades, their unused runtime factory, and
the cross-provider telemetry shim. The native WebGPU object API and drop-in C
ABI remain a separately governed object/FFI execution surface; they are not
misreported as consumers of the canonical command runner. Structural gates
still do not substitute for physical AMD/Windows or Fawn-browser
qualification.

## Classification

The ownership inventory is generated in
[`runtime/zig/src/README.md`](../../runtime/zig/src/README.md). Use it to locate
WebGPU ABI commands, native object/resource/lifecycle implementations, shared
execution services, and backend mechanics. The runtime README links to that
inventory instead of maintaining a second directory map.

Build reachability is independently classified by the manifest's named views.
`full/modules/` remains module incubation; `core/` and `full/` are historical
capability partitions for ABI commands. `native/` owns WebGPU objects and native
provider integration. None of these directory names alone establishes shipment
or physical qualification. Compatibility facades retain their manifest-owned
consumers and removal conditions.

Browser receipt validation is organized by artifact responsibility under
`bench/browser/release/`; the admission gate and readiness builder consume the
same implementation. Its behavior-preserving move and the original stale
positive-fixture failure are retained in
`bench/out/organization/20260905-browser-receipts/`.
Remaining archive/proof/frontier workflows still need their named semantic
splits. Retained historical evidence is not duplicate implementation.

Nursery is archive navigation under `config/tool-surfaces.json`. Current CI
uses `browser/chromium/` and `bench/cts/`; AGENTS and the nursery README agree
with those consumers. Old source paths remain in historical receipts.

## Reuse and deduplication findings

### Reachability accounting caveat

The aggregate architecture graph still means “reachable from a declared source
root,” not “required by the shipped native runtime.” Named view evidence now
separates:

- shipped native/package runtime;
- drop-in and compatibility surfaces;
- module-incubation and benchmark tools;
- compiler/TSIR/spatial toolchains.

Modules absent from all named views are not deleted automatically. Package
facades are reported separately because build-module alias selection is lazy
and cannot be inferred from relative-import edges alone. Any remaining
unclassified implementation requires an exact consumer audit before removal.

The source-layout manifest records the important canonicalization decisions:

- `src/contracts/capability.zig` supersedes
  `src/backend/common/capabilities.zig`.
- `src/contracts/command.zig` supersedes the model, core, and full command
  registry paths listed as forbidden legacy paths.
- `src/contracts/execution.zig` supersedes `src/backend/common/errors.zig`.
- `src/compat/webgpu_ffi.zig` is an intentional external facade with a named
  consumer, test, owner, and removal condition.

The forbidden legacy files are absent from the current tree, and the current
Zig sources do not import them. That is evidence that this particular contract
deduplication has already landed. Keep the forbidden-path entries as guards;
remove them only when the compatibility and migration history no longer needs
the protection.

Metal, Vulkan, and D3D12 should not be merged into one implementation. Their
platform mechanics are correctly separate. The reuse target is the semantic
layer above them: contracts, command meaning, capability policy, artifact
identity, timing, trace, and error taxonomy.

## Architecture follow-up

1. Keep the forbidden legacy paths guarded and verify new code imports the
   canonical contracts.
2. Keep `src/full/modules/` classified as module incubation and ensure its
   deterministic contract results are never promoted as physical GPU evidence.
3. Move test-only compatibility aggregators out of production source after
   their consumers import narrow canonical contracts.
4. Review the remaining high-confidence seams named by the duplicate report:
   TSIR emitter selection and identity assembly, backend artifact/timing, and
   module request parsing. Consolidate only when semantic tests cover every
   consumer, and keep platform API and target-specific lowering mechanics
   separate.
5. Split only the files that exceed the advisory architecture signal when the
   split follows a real responsibility boundary.
6. Re-run import-fence, source-layout, core tests, WGSL tests, and package tests
   after each migration.

The earlier correction deleted only disconnected barrels and the unconsumed
render-runtime chain. The current correction also removes an undocumented
Metal-dispatch side effect: HostPlan evidence must now be produced by an
explicit plan or benchmark lane. The evidence supports “layered with
module-incubation separation and targeted file review,” not “rewrite the
runtime” or “everything is already optimally abstracted.”
