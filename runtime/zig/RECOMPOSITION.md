# Doe Zig Recomposition Plan

The plan has the right instincts, but it is still too **file-size driven**. That
risks repeating the mechanism that produced the fragmentation: identify a large
file, split it until it passes the limit, add forwarding modules, and preserve
every old import path.

The inventory has the signature of a hard-cap architecture: Doe has 687 Zig
files and 197,486 physical lines, including production, tests, benchmarks,
build files, and integrations. Twenty production files sit at 900 lines or
more; fourteen are between 980 and 999 lines, including two at exactly 999. At
the other end are many 7–40-line files.

Small is not automatically bad. The seven-line D3D12 bridge isolates an
`@cImport`, which is a legitimate FFI boundary. The seven-line plan executables
are legitimate process roots.

The actual problem is:

> Too many semantic facts have multiple owners, while too many files have no
> semantic identity of their own.

The objective is:

> One authoritative owner for every contract; one narrow public surface per
> subsystem; private implementation behind it; no duplicated registries,
> profile unions, policies, mappings, errors, or artifact definitions.

A reasonable expected outcome is 15–25% fewer production Zig files, but that
is a campaign objective, not an architectural correctness gate.

## 1. Freeze behavior before reorganizing anything

Do not start by splitting the 999-line files. First create a behavior and
artifact baseline at one named commit.

Capture:

- Every public Zig module and public declaration reachable through
  `@import("doe")`.
- Exported C ABI symbols from the shared libraries.
- Command JSON parsing results and normalized command representations.
- WGSL-to-IR and WGSL-to-MSL/SPIR-V/HLSL/CSL semantic digests.
- Trace rows, terminal trace hashes, replay results, and receipt identities.
- Backend capability reports and unsupported-error classifications.
- Representative Metal, Vulkan, and D3D12 compute results.
- Clean and incremental compilation timings.
- Hot-path benchmark medians and binary sizes.

Write this to:

```text
runtime/zig/reports/recomposition/baseline.json
runtime/zig/reports/recomposition/public-api.json
runtime/zig/reports/recomposition/exported-symbols.txt
runtime/zig/reports/recomposition/semantic-fixtures/
```

Every structural change has three possible outcomes:

1. Exact semantic equivalence.
2. Explicitly approved contract change.
3. Failure.

No refactor may silently change an error name, receipt field, generated shader,
fallback decision, public import path, or synchronization behavior.

## 2. Upgrade `source-layout.json` from a directory inventory into an architecture manifest

Doe already has `source-layout.json`, but version 1 primarily declares
top-level owners, allowed roots, WGSL stage directories, and compatibility
facades. The current checker enforces directory shape and compatibility-import
restrictions, but not the complete dependency architecture described in the
style guide.

Extend it to version 2 rather than creating another disconnected policy file:

```json
{
  "version": 2,
  "layers": {
    "contracts": {
      "globs": ["src/contracts/**"],
      "mayImport": ["contracts"]
    },
    "compiler": {
      "globs": ["src/compiler/**"],
      "mayImport": ["contracts", "compiler", "verification"]
    },
    "runtime": {
      "globs": ["src/runtime/**", "src/core/**", "src/full/**"],
      "mayImport": ["contracts", "runtime", "backend-interface"]
    },
    "backend-common": {
      "globs": ["src/backend/common/**"],
      "mayImport": ["contracts", "backend-common", "compiler-artifacts"]
    },
    "backend-concrete": {
      "globs": [
        "src/backend/metal/**",
        "src/backend/vulkan/**",
        "src/backend/d3d12/**"
      ],
      "mayImport": [
        "contracts",
        "backend-common",
        "backend-concrete-self",
        "compiler-artifacts"
      ]
    },
    "surface": {
      "globs": [
        "src/native/**",
        "src/dropin/**",
        "src/cli/**",
        "src/plan/**"
      ],
      "mayImport": ["contracts", "runtime", "backend-interface", "surface"]
    }
  },
  "specialRoles": {
    "entrypoint": ["src/cli/entrypoints/*.zig"],
    "ffiBoundary": ["src/backend/**/*bridge*.zig"],
    "generated": [],
    "compatibilityFacade": ["src/compat/webgpu_ffi.zig"]
  }
}
```

The exact layering can be refined, but several rules immediately become
absolute:

- `contracts` may never import `core`, `full`, `runtime`, `native`, or a
  concrete backend.
- Metal, Vulkan, and D3D12 may not import each other.
- Backend-neutral runtime code may not import concrete backend implementation
  files.
- Promoted production code may not import `experimental`.
- Internal implementation may not import a broad compatibility barrel.
- Every compatibility facade must declare its external consumer, reason, test,
  owner, and removal condition.

This turns architectural prose into executable policy.

## 3. Build a semantic inventory, not merely a line-count inventory

Extend `check_source_layout.py` into a two-stage analyzer.

### Stage A: graph and ownership scan

A Python scanner can reliably identify literal Zig imports and resolve relative
paths. For every production file, record:

```text
path
owner
architectural layer
special role
physical lines
top-level declaration count
public declaration count
test-block count
imports
reverse imports
fan-in
fan-out
whether it contains @cImport
whether it defines main()
whether it only re-exports symbols
whether it is reachable from a production root
```

Run Tarjan’s algorithm over the import graph to find strongly connected
components. No external graph dependency is required.

### Stage B: declaration and similarity scan

Add a small Zig tool built on `std.zig.Ast` to emit:

- Function boundaries and lengths.
- Struct, union, and enum declarations.
- Top-level constants.
- Public symbol names.
- Normalized token hashes for declaration bodies.
- Switch-tag sets.
- Repeated literal tables and constant families.

Combine that with Git history:

```bash
git log --name-only --format= -- runtime/zig/src
```

Exclude mass-format, generated, and pure-rename commits, then calculate pairwise
co-change frequency. Co-change is diagnostic evidence, not an automatic merge
command.

The analyzer emits:

```text
reports/architecture/modules.json
reports/architecture/import-graph.dot
reports/architecture/cycles.json
reports/architecture/forbidden-edges.json
reports/architecture/duplicate-declarations.json
reports/architecture/merge-candidates.json
reports/architecture/split-candidates.json
reports/architecture/unreachable-files.json
```

### Classification rules

Every file receives one of five decisions:

**Keep** when it is an executable root, package root, C/OS/ABI boundary,
independently meaningful algorithm, generated specification, or stable contract
used by multiple owners.

**Merge** when it has one production importer, no independent test or build
identity, the same owner as its consumer, and contains only forwarding
declarations, a tiny private record, or private constants.

**Elevate** when multiple layers need the same fact but the file currently lives
inside one implementation. Move it to the semantic owner.

**Recompose** when a file contains multiple state machines, policies, contexts,
or pipeline phases. Recomposition may produce fewer or more files; the
criterion is one responsibility per module.

**Delete** when it is unreachable, superseded, duplicated, or a compatibility
facade with no remaining declared consumer.

This is safer than auditing large files and then auditing small files.

## 4. Fix duplicate sources of truth before touching the large emitters

The highest-leverage defect is not a 999-line file. It is the command model.

`contracts/model/model_commands.zig` defines the combined command enum and
union, but also imports `core/command_partition.zig` and
`full/command_partition.zig`. Those partition files repeat command tags,
payload mappings, and identical `fromCombined`, `contains`, and `name` helpers.
The contract layer therefore depends backward on implementation/profile layers
while maintaining three representations of the same command taxonomy.

That conflicts with Doe’s dependency direction: contracts sit below subsystem
implementations, and `core` remains one-way relative to `full`.

### Replace the three command definitions with one registry

Create one authoritative module:

```text
src/contracts/command.zig
```

It owns:

```zig
pub const Scope = enum {
    core,
    full,
};

pub const Kind = enum(u8) {
    upload,
    buffer_write,
    copy_buffer_to_texture,
    barrier,
    dispatch,
    dispatch_indirect,
    kernel_dispatch,
    render_draw,
    // ...
};

pub const Command = union(Kind) {
    upload: resource.UploadCommand,
    buffer_write: resource.BufferWriteCommand,
    copy_buffer_to_texture: resource.CopyCommand,
    barrier: resource.BarrierCommand,
    dispatch: compute.DispatchCommand,
    dispatch_indirect: compute.DispatchIndirectCommand,
    kernel_dispatch: compute.KernelDispatchCommand,
    render_draw: render.RenderDrawCommand,
    // ...
};

pub const Metadata = struct {
    scope: Scope,
    trace_name: []const u8,
    capability: Capability,
};

pub const metadata = std.EnumArray(Kind, Metadata).init(.{
    .upload = .{
        .scope = .core,
        .trace_name = "upload",
        .capability = .buffer_upload,
    },
    // ...
});
```

Initially, keep the tagged union explicit. Do not introduce complicated
`@Type` generation merely to eliminate a few declarations. The first goal is
one source of truth.

Derive from this registry:

- Core/full classification.
- Trace names.
- Parser dispatch.
- Serialization names.
- Capability requirements.
- Unsupported taxonomy.
- Test coverage expectations.
- Command-handler coverage checks.

Then:

- Delete `core/command_partition.zig`.
- Delete `full/command_partition.zig`.
- Remove `CoreCommand`, `FullCommand`, `as_core_command`, and
  `as_full_command`.
- Make core and full dispatchers consume the authoritative `Command` directly.
- Add compile-time coverage proving every `Kind` has metadata and exactly one
  owning execution scope.

The existing core and full dispatchers are small and readable; their
duplication is acceptable only at the backend-routing level. Their duplicated
taxonomy and conversion machinery is not.

Repeat this treatment in order for:

1. Command kinds and payloads.
2. Capability and feature identities.
3. Error and unsupported classifications.
4. Artifact identity and hash fields.
5. Timing and dispatch-result semantics.
6. Texture-format and binding mappings.
7. Backend selection and fallback policy.

Each family gets one semantic owner. Backend-specific conversion remains local
to that backend.

## 5. Elevate misplaced contracts instead of merging them into their current neighbors

An eight-line file may be in the wrong place rather than unnecessary.

For example, `hlsl_dispatch_contract.zig` defines register slots, buffer size,
and shader-visible field names. The D3D12 runtime imports it from inside the
WGSL HLSL emitter. That means the runtime backend depends on an emitter-internal
path for a shared host/shader ABI.

Do not merge that file into `emit_hlsl.zig`. Move it to:

```text
src/contracts/shader_abi/dispatch_info.zig
```

Then both the HLSL emitter and D3D12 runtime depend on the neutral ABI contract.

The decision pattern is:

- **Private to one implementation:** merge into its owner.
- **Used across layers:** elevate to a neutral contract.
- **FFI or executable boundary:** keep small.
- **Parallel but semantically different backend logic:** keep separate.

DRY eliminates duplicate knowledge; it does not force Metal, Vulkan, and D3D12
synchronization logic through a generic callback machine.

## 6. Replace broad barrels with namespaced subsystem APIs

`contracts/model/model.zig` manually re-exports a large flat set of GPU
constants and model types. `src/mod.zig` similarly exposes many imports through
functions returning module types, such as `doe.plan.doeExecutor()` and
`doe.compiler.wgsl()`.

Prefer:

```zig
pub const contracts = @import("contracts/mod.zig");
pub const compiler = @import("compiler/mod.zig");
pub const runtime = @import("runtime/mod.zig");
pub const backend = @import("backend/mod.zig");
pub const plan = @import("plan/mod.zig");
```

Inside contracts:

```zig
pub const command = @import("command.zig");
pub const resource = @import("resource.zig");
pub const compute = @import("compute.zig");
pub const render = @import("render.zig");
pub const texture = @import("texture.zig");
pub const gpu = @import("gpu.zig");
```

Internal code imports the narrow module it uses. The flat compatibility API
exists only when an external package consumer requires it.

Compatibility policy:

- Internal rename or move: migrate all consumers and delete the old path in the
  same change.
- Published package or ABI contract: retain one tested facade.
- Every retained facade must be declared in `source-layout.json`.
- A facade may contain no policy or behavior.
- A facade with no actual consumer is deleted immediately.

Tiny executable roots remain tiny. They are not compatibility facades and do
not need artificial implementation content.

## 7. Validate the architecture with one promoted vertical path

After the command registry is canonical, refactor the kernel-dispatch path
first:

```text
command JSON
    ↓
contracts.command.Command
    ↓
application preparation
    ↓
read-only PreparedOperation
    ↓
capability-specific backend port
    ↓
Metal / Vulkan / D3D12 compute implementation
    ↓
NativeExecutionResult
    ↓
trace, receipt, and benchmark artifacts
```

Kernel dispatch is the right pilot because Doe’s promoted wedge is Node/Bun
compute, while browser replacement and spatial targets remain expansion lanes.

### Introduce explicit state slices

Many execution functions accept `anytype`, which hides their dependencies.
Replace this gradually with narrow contexts:

```zig
pub const ComputeContext = struct {
    device: *DeviceState,
    queue: *QueueState,
    resources: *ResourceTable,
    pipelines: *PipelineCache,
    diagnostics: *Diagnostics,
};

pub const DispatchRequest = struct {
    kernel: ShaderArtifact,
    workgroups: WorkgroupCount,
    bindings: []const KernelBinding,
    repeat: u32,
};

pub const DispatchReport = struct {
    prepare_ns: u64 = 0,
    encode_ns: u64 = 0,
    submit_ns: u64 = 0,
    wait_ns: u64 = 0,
    dispatch_count: u32 = 0,
    gpu_timing: GpuTiming = .unavailable,
};
```

Backends translate `DispatchRequest` into their native calls and return the
same neutral `DispatchReport`. Backend extensions may exist, but
receipt-bearing common fields get one definition.

Share across backends:

- Validation.
- Command and capability contracts.
- Workgroup normalization.
- Artifact identity.
- Timing result semantics.
- Error taxonomy.
- Pure layout calculations.

Keep backend-local:

- Resource transitions.
- Command encoder creation.
- Descriptor allocation.
- Fence and semaphore behavior.
- Native lifetime rules.
- Driver workarounds.
- Submission batching mechanics.

For the pilot, require exact equality of normalized outputs, errors, trace
identities, and artifact digests. Benchmark the old and new paths on the same
fixed workloads before deleting the former path.

Then apply the proven pattern in order:

1. Buffer upload and writes.
2. Copy commands.
3. Pipeline creation and caches.
4. Render commands.
5. Surface and presentation lifecycle.
6. Async diagnostics and queries.

## 8. Recompose each domain according to its own structure

A universal split-at-N-lines rule cannot work across this repository.

### Compiler

Preserve real pipeline stages:

```text
frontend → semantic model → IR → transforms → proof → target emitter
```

A target emitter normally exposes:

```text
mod.zig       public target API
context.zig   emitter-owned mutable state
types.zig     target-specific semantic types
lower.zig     IR traversal and lowering
builtins.zig  builtin mappings
serialize.zig target binary/text serialization
```

Only create those files when each owns real behavior. Specialized CSL
operations such as attention, reductions, quantization, and matmul may deserve
separate files because they are independent lowering families. Tiny
one-consumer helpers do not.

Large mapping switches should become typed tables generated from the canonical
IR or target schema where practical.

### Backends

Each concrete backend exposes one internal capsule:

```text
device
queue
resources
pipelines
commands
surface
diagnostics
ffi
```

Do not create one file per minor struct. Put a private state or metrics record
next to its sole owner. Keep isolated FFI imports and major resource domains
separate.

### ABI and WebGPU types

Audit `core/abi` as a generation candidate. If multiple files manually
reproduce one upstream WebGPU ABI, establish one checked-in schema or pinned
header input and generate:

- Enums and records.
- Callback declarations.
- Proc types and proc tables.
- Loader metadata.
- Capability inventory.
- ABI conformance tests.

Generated outputs may remain physically split for compiler performance, but
developers edit one source of truth.

### Tests

Do not apply the same file-count policy to tests.

Use:

- Inline tests for private, pure, local behavior.
- External tests for integration, ABI, backend behavior, golden artifacts, and
  cross-module characterization.
- One domain-local fixture module where multiple tests genuinely share setup.
- Generated test-suite imports rather than manually maintained aggregator
  lists.

## 9. Replace the 999-line rule with architecture-aware gates

Do not keep 999 lines as the primary hard design rule. The clustering
immediately below 999 shows that it is shaping files more strongly than
semantic ownership.

During the transition, retain it as a ratchet so files do not grow unchecked.
Once the architecture checks are operational, use:

- 800 lines: advisory review signal.
- 1,200 lines: requires an explicit cohesive-module justification.
- 1,500 lines: hard maximum for handwritten production code.
- Generated specification/table files: separately declared and reproducibly
  generated.
- No limit-based split accepted unless the new modules have distinct named
  responsibilities.

More important blocking gates are:

1. Zero import cycles.
2. Zero forbidden layer edges.
3. Zero imports from contracts into implementation layers.
4. Zero concrete-backend sibling imports.
5. Every source file owned by a declared subsystem.
6. Every compatibility facade declared and exercised.
7. No promoted code importing experimental code.
8. No unreachable production modules.
9. Every command, capability, and error identity represented in its canonical
   registry.
10. No public API expansion without an explicit manifest diff.

Diagnostic, non-blocking observations include:

- Total production file count.
- One-consumer module count.
- Re-export-only file count.
- Public declarations per subsystem.
- Fan-in and fan-out percentiles.
- Co-change coupling.
- File-size distribution.
- Clean and incremental build time.

These metrics are ratcheted against a baseline, not assigned arbitrary
universal ideals.

## Implementation checklist

- [x] Record the baseline commit, toolchain identity, host identity, and policy hashes in `runtime/zig/reports/recomposition/baseline.json`.
- [x] Inventory every public Zig module and public declaration reachable through `@import("doe")` into `runtime/zig/reports/recomposition/public-api.json`.
- [x] Inventory exported C ABI symbols from every promoted shared-library artifact into `runtime/zig/reports/recomposition/exported-symbols.txt`.
- [x] Capture command JSON inputs, parsing results, normalized command representations, error names, and unsupported classifications as semantic fixtures.
- [x] Capture WGSL-to-IR and WGSL-to-MSL/SPIR-V/HLSL/CSL semantic and output digests as immutable fixtures.
- [x] Capture trace rows, terminal trace hashes, replay results, receipt identities, and first failure boundaries for the promoted paths.
- [ ] Capture backend capability reports and representative Metal, Vulkan, and D3D12 compute outputs with explicit hardware/runtime identity.
  - Metal and Vulkan are captured and receipt-bound in `runtime/zig/reports/recomposition/backend-evidence.json`; D3D12 remains a separate Windows-host obligation.
  - Schema version 4 preserves already captured backends while another host
    adds a comparable, hash-bound native report. Each captured backend owns its
    own `evidenceHost`; the cumulative receipt has no ambiguous last-writer
    host identity. Run the
    matching command from the repository root:

    ```bash
    python3 bench/runners/run_recomposition_backend_evidence.py \
      --backend vulkan

    python3 bench/runners/run_recomposition_backend_evidence.py \
      --backend metal

    python3 bench/runners/run_recomposition_backend_evidence.py \
      --backend d3d12
    ```

    Each command preflights the host, runs Doe and Dawn separately through the
    promoted smoke contract, compares their receipts strictly, verifies the
    physical adapter, host/API/backend identities, fallback status, receipt
    hashes, dispatch shape, and output oracles, then merges its backend into
    the canonical receipt.
- [x] Capture clean and incremental compilation measurements, promoted hot-path benchmark medians, and binary sizes without turning them into universal claims.
- [x] Add one baseline verifier that classifies a structural result as exact equivalence, approved contract change, or failure.
- [x] Extend `runtime/zig/source-layout.json` to version 2 instead of creating another architecture policy file.
- [x] Declare architecture layers, globs, permitted imports, special roles, production roots, generated sources, and compatibility facades in the version-2 manifest.
- [x] Require every compatibility facade entry to name its external consumer, reason, owner, exercising test, and removal condition.
- [x] Extend `runtime/zig/tools/check_source_layout.py` to resolve every literal production Zig import into an owner and architecture layer.
- [x] Enforce zero imports from contracts into implementation layers.
- [x] Enforce zero concrete-backend sibling imports.
- [x] Enforce zero backend-neutral imports of concrete backend implementation files.
- [x] Enforce zero promoted-production imports of `experimental`.
- [x] Enforce zero internal implementation imports of compatibility barrels.
- [x] Implement Tarjan strongly connected components and fail on production import cycles.
- [x] Compute production-root reachability and fail on unreachable production modules unless the manifest declares a justified special role.
- [x] Emit `reports/architecture/modules.json` with owner, layer, role, lines, declarations, tests, imports, reverse imports, fan-in, fan-out, FFI/root/facade classification, and reachability.
- [x] Emit `reports/architecture/import-graph.dot`, `cycles.json`, `forbidden-edges.json`, and `unreachable-files.json` deterministically.
- [x] Add a Zig `std.zig.Ast` analyzer for function boundaries, declaration kinds, public symbols, normalized token hashes, switch-tag sets, repeated literal tables, and constant families.
- [x] Add Git-history co-change analysis that excludes mass-format, generated, and pure-rename commits.
- [x] Emit deterministic duplicate-declaration, merge-candidate, split-candidate, and co-change reports.
- [x] Assign every production Zig file exactly one reviewed decision: Keep, Merge, Elevate, Recompose, or Delete.
- [x] Keep executable roots, package roots, ABI/FFI boundaries, generated specifications, shared contracts, and independently meaningful algorithms when their identity is verified.
- [x] Merge one-consumer forwarding modules and private constant/record shards only when they share an owner and have no independent contract or test identity.
- [x] Elevate cross-layer semantic facts to neutral contract owners before merging neighboring implementation files.
- [x] Recompose multi-state-machine and multi-phase files by named semantic responsibility rather than by line count.
- [x] Delete unreachable, superseded, duplicated, and unconsumed compatibility modules with public-surface and receipt verification.
- [x] Create `src/contracts/command.zig` as the authoritative explicit command kind, payload, scope, trace-name, capability, and coverage registry.
- [x] Make command JSON parsing and serialization consume the authoritative command registry.
- [x] Make trace naming and unsupported classification consume the authoritative command registry.
- [x] Make core and full execution routing consume the authoritative `Command` directly.
- [x] Add compile-time coverage proving every command kind has metadata and exactly one execution scope.
- [x] Delete `core/command_partition.zig` and `full/command_partition.zig` after all consumers migrate.
- [x] Delete `CoreCommand`, `FullCommand`, `as_core_command`, `as_full_command`, and repeated tag/name conversion machinery.
- [x] Canonicalize capability and feature identities under one neutral owner.
- [x] Canonicalize error and unsupported classifications under one neutral owner.
- [x] Canonicalize artifact identity and hash fields under one neutral owner.
- [x] Canonicalize timing and dispatch-result semantics under one neutral owner.
- [x] Canonicalize texture-format and binding mappings under one neutral owner.
- [x] Canonicalize backend selection and fallback policy while retaining backend-native control flow.
- [x] Move `hlsl_dispatch_contract.zig` semantics into `src/contracts/shader_abi/dispatch_info.zig`.
- [x] Migrate both the HLSL emitter and D3D12 runtime to the neutral shader ABI contract.
- [x] Inventory other cross-layer imports of implementation-internal contracts and classify each for elevation, local merge, or deletion.
- [x] Introduce namespaced subsystem roots for contracts, compiler, runtime, backend, and plan without changing public semantics.
- [x] Replace the flat model barrel with narrow command, resource, compute, render, texture, and GPU namespaces.
- [x] Migrate internal consumers to the narrow owner modules they actually use.
- [x] Retain only externally required flat compatibility surfaces, declare them in the architecture manifest, and exercise them through consumer tests.
- [x] Delete every facade with no declared external consumer.
- [x] Define explicit neutral `ComputeContext`, `DispatchRequest`, and `DispatchReport` contracts for the promoted kernel-dispatch path.
- [x] Replace boundary-hiding `anytype` parameters in the promoted dispatch path with the explicit context/request/report contracts.
- [x] Route command JSON through the canonical command, immutable prepared operation, narrow compute port, concrete implementation, neutral result, trace, and receipt path.
- [x] Share validation, command/capability contracts, workgroup normalization, artifact identity, timing semantics, error taxonomy, and pure layout calculations across backends.
- [x] Keep resource transitions, encoder creation, descriptor allocation, fences/semaphores, native lifetimes, driver workarounds, and submission batching backend-local.
- [x] Prove exact normalized-output, error, trace-identity, receipt, and artifact-digest equality between the old and new kernel-dispatch paths in `runtime/zig/reports/recomposition/kernel-dispatch-equivalence.json`.
  Reproduce on an admitted AMD Vulkan host with:

  ```bash
  python3 runtime/zig/tools/capture_kernel_dispatch_equivalence.py \
    --vulkan-icd /path/to/physical-amd-icd.json
  ```
- [x] Benchmark old and new kernel-dispatch paths on identical fixed workloads before deleting the former path.
- [x] Delete temporary characterization adapters and the former kernel-dispatch path after equivalence and performance checks pass; retain the immutable approvals in `runtime/zig/reports/recomposition/kernel-dispatch-equivalence.json` and `runtime/zig/reports/recomposition/kernel-dispatch-performance-approval.json`.
- [x] Apply the proven execution-contract pattern to buffer upload and writes.
- [x] Apply the proven execution-contract pattern to copy commands.
- [x] Apply the proven execution-contract pattern to pipeline creation and caches.
- [x] Keep immutable kernel-source roots separate from mutable provider pipeline-cache storage.
- [x] Apply the proven execution-contract pattern to render commands.
- [x] Apply the proven execution-contract pattern to surface and presentation lifecycle.
- [x] Apply the proven execution-contract pattern to async diagnostics and queries.
- [x] Recompose compiler targets around real API, context, types, lowering, builtins, and serialization responsibilities only where each owns behavior.
- [x] Replace large repeated compiler mapping switches with typed tables derived from canonical IR or target schemas where practical.
- [x] Recompose each concrete backend into device, queue, resources, pipelines, commands, surface, diagnostics, and FFI capsules without creating one file per minor record.
- [x] Audit `core/abi` for duplicated upstream WebGPU definitions and select one checked-in schema or pinned header as the editable source of truth.
- [x] Generate ABI enums, records, callbacks, proc types/tables, loader metadata, capability inventory, and conformance tests when the audit proves duplication.
- [x] Formalize inline tests for private local behavior and external tests for integration, ABI, backend, golden, characterization, and cross-backend behavior.
- [x] Consolidate genuinely shared test setup into domain-local fixtures.
- [x] Generate test-suite imports from the owned test inventory and remove parallel manual aggregator lists.
- [x] Keep the 999-line checker as a no-growth transition ratchet until architecture version 2, cycle, edge, reachability, and baseline gates are active.
- [x] After those gates are active, update `AGENTS.md`, `STYLE.md`, `source-layout.json`, and the line checker together to make 800 advisory, require justification above 1,200, and hard-fail handwritten production source above 1,500.
- [x] Require every generated specification or table file to declare its reproducible generator, inputs, owner, reason, and generated-output check separately.
- [x] Reject every size-driven split whose resulting modules lack distinct named responsibilities.
- [x] Add blocking gates for canonical command, capability, and error registry completeness.
- [x] Add a blocking public API manifest-diff gate.
- [x] Emit non-blocking architecture observations for production file count, one-consumer modules, re-export-only modules, subsystem public declarations, fan-in/fan-out percentiles, co-change, file-size distribution, and source-bound build measurements.
- [x] Ratchet architecture observations against the captured baseline without treating arbitrary file-count or distribution targets as correctness gates.
- [ ] Verify the definition of done: one owner per semantic family, no forbidden contract dependencies, no duplicated core/full taxonomy, narrow internal imports, justified tiny files, declared facades, backend-local native control flow, and equivalent digests, receipts, replay, ABI, outputs, and promoted performance.

## Definition of done

The campaign is complete when:

- Every command, capability, error class, artifact identity, and timing field has
  one authoritative definition.
- `contracts` has no implementation-layer imports.
- `core`/`full` duplication has been replaced by capability or scope metadata
  where appropriate.
- Internal code imports narrow owner modules rather than flat barrels.
- Every tiny file is demonstrably a root, boundary, contract, generated
  artifact, or independently meaningful implementation.
- Every facade has a real external consumer and an explicit lifecycle.
- No backend shares native control flow merely to reduce textual repetition.
- Semantic digests, receipts, replay, ABI exports, and promoted outputs remain
  equivalent.
- File count has fallen materially as a consequence of stronger ownership, not
  because cohesive modules were mechanically fused into monoliths.
