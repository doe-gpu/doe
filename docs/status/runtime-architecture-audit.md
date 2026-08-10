# Runtime architecture audit

This is the current classification of Doe's non-test Zig surfaces. It is an
architecture review, not a claim that every line is promoted product code.
The import fence and source-layout gates are the structural authority; this
page records the lifecycle interpretation and follow-up decisions.

## Current canonicalization pass

The latest source-layout evidence incorporates two boundary corrections:

- `src/compiler/wgsl/mod.zig` is now a compatibility facade. Analysis,
  diagnostics, binding reflection, override application, and per-target
  translation live under `src/compiler/wgsl/pipeline/`; shipped backend and
  native consumers import only the stage and target they execute.
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

## Classification

| Surface | Classification | Boundary decision |
| --- | --- | --- |
| `src/contracts/` | Canonical | Shared semantic contracts. New consumers should import these rather than backend or model-specific copies. |
| `src/compiler/wgsl/` | Canonical | WGSL parsing, IR, transforms, proofs, and target emission. `mod.zig` is the compatibility facade; runtime code imports narrow `pipeline/` stages. Keep lowering separate from native execution. |
| `src/compiler/tsir/` | Diagnostic/canonical research path | Doe-owned portability path with real contracts, but broad target execution is not yet promoted. |
| `src/backend/common/` | Canonical shared implementation | The current helpers import canonical contracts and are reused by backend paths; no merge is justified from this audit. |
| `src/backend/metal/`, `vulkan/`, `d3d12/` | Canonical platform components | Keep separate because the native APIs, synchronization, memory, and failure models differ. Reuse policy, contracts, tracing, and common helpers. |
| `src/native/` | Canonical runtime | Doe-native WebGPU objects, resource ownership, commands, and lifecycle. Backend mechanics should remain below shared runtime contracts. |
| `src/runtime/` | Canonical shared services | Queues, cache, device, lifecycle, diagnostics, execution policy, and trace services shared by runtime paths. |
| `src/core/` | Canonical compute core | Narrower WebGPU/compute ABI and shared core behavior. It must not become a second full-runtime implementation. |
| `src/full/` | Mixed: canonical full surface plus module incubation | Full WebGPU behavior is a valid surface; `src/full/modules/rendering` and `services` are reachable through `module-core-runner`, package tooling, and module gates, but are not native GPU execution evidence. |
| `src/dropin/` and `src/compat/` | Compatibility surfaces | Keep only for declared consumers and tests. Facades need removal conditions, not silent permanence. |
| `src/spatial/` | Diagnostic target path | HostPlan/CSL tooling is Doe-owned, but simulator or bootstrap output is not general hardware evidence. |
| `src/integrations/` | Repo-only integration seams | Keep external adapters isolated from the runtime product contract. |
| `src/plan/`, `src/command/`, `src/quirk/`, `src/verification/` | Supporting runtime layers | Keep separate where they own distinct policy, normalization, or proof boundaries. |
| `src/cli/`, `runtime/zig/tools/`, `runtime/zig/bench/` | Tooling | Not runtime product code; do not use their size as evidence of runtime capability. |
| `src/core/abi/generated/` | Generated | Maintain through the generator contract; do not hand-refactor generated ABI. |

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
