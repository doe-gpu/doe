# Doe Zig ideal architecture and migration plan

**Repository basis:** `doerun/doe` at commit `b099ca3c14fc1b3f6d7b42abd3131d5b84d23631`.

**Implementation status (2026-08-22):** The structural migration described
below is complete. `BackendRuntime`, `BackendIface`, `BackendVTable`, and the
backend registry have been removed; concrete providers bind directly to narrow
ports and only the composition backend factory imports multiple providers.
Historical migration sections retain the names of removed starting-state files
so the sequence and deletion criteria remain auditable. Physical AMD Vulkan,
Windows D3D12, and Fawn browser qualification remain separate evidence gates.

![Doe Zig target architecture](../assets/architecture/doe-zig-hexagonal-box-diagram.svg)

## Why “hexagonal”

“Hexagonal” does not mean drawing a six-sided shape or arranging every directory in concentric rings. It means the stable application behavior is isolated from the mechanisms that call it and the mechanisms it calls.

Doe has many inbound mechanisms:

- CLI commands
- JSON command streams
- the native WebGPU object API
- the drop-in C ABI
- direct plans and replay
- ONNX Runtime integration
- spatial and CSL tools

Doe also has many outbound mechanisms:

- Metal
- Vulkan
- D3D12
- Dawn and WebKit delegates
- Cerebras CSL execution
- trace, receipt, replay, and artifact storage

Those mechanisms should not define Doe’s semantics. They should translate into or implement stable ports. The center should own commands, identity, validation, specialization, preparation, execution policy, lifecycle requirements, and evidence requirements. Concrete providers remain replaceable leaf nodes.

The actual Zig import graph remains a DAG. “Hexagonal” describes the dependency boundary inside that DAG:

```text
inbound adapter → application use case → stable contracts
                                    ↓
                              outbound port
                                    ↓
                            concrete adapter
```

The core never imports a concrete backend. A Metal, Vulkan, D3D12, delegate, or CSL adapter implements a port selected by a composition root.

## Target dependency law

The final architecture should enforce this partial order:

```text
contracts
   ↑
compiler      quirk      verification      backend ports      evidence port
   ↑             ↑             ↑                 ↑                  ↑
                         application orchestration
                                   ↑
                            runtime services
                                   ↑
 inbound adapters / composition roots       concrete outbound adapters
```

More concretely:

1. `contracts/` imports only `contracts/`.
2. `compiler/`, `quirk/`, and `verification/` may import contracts and their own modules.
3. `backend/ports/` may import contracts only.
4. `runtime/` may import contracts and backend ports, but not concrete backends.
5. `app/` may import contracts, compiler, quirk, verification, runtime, backend ports, and the evidence port.
6. Concrete backend adapters may import contracts, backend ports, backend-local code, and narrowly approved native helpers. They may not import another backend.
7. Inbound adapters may import contracts and the application facade. They may not import concrete backends.
8. `composition/` is the only layer allowed to import both application/runtime construction and concrete adapters.
9. `evidence/` observes requests, prepared operations, execution reports, and lifecycle results. It never changes provider selection or execution semantics.
10. Compatibility facades re-export or delegate only. They own no policy or state.

## Target directory tree

The least disruptive target keeps the current public top-level adapter directories while introducing missing architectural owners:

```text
runtime/zig/src/
├── mod.zig
├── contracts/                     stable domain language
│   ├── command.zig
│   ├── capability.zig
│   ├── error.zig                  new canonical error taxonomy
│   ├── exactness.zig              new oracle/exactness classes
│   ├── artifact.zig
│   ├── identity.zig               new source/program/execution identities
│   ├── ownership.zig              new resource and lifecycle ownership
│   ├── prepared_operation.zig     new immutable execution unit
│   ├── execution_report.zig       new common result/timing contract
│   ├── evidence.zig               new evidence requirements and port values
│   ├── backend.zig
│   ├── binding.zig
│   ├── texture.zig
│   ├── texture_format.zig
│   ├── shader_abi/
│   ├── numeric_stability/
│   └── model/                     temporary compatibility; shrink over time
├── app/                           new application/use-case layer
│   ├── request.zig
│   ├── normalize.zig
│   ├── validate.zig
│   ├── specialize.zig
│   ├── compile.zig
│   ├── bind.zig
│   ├── schedule.zig
│   ├── prepare.zig
│   ├── execute.zig
│   ├── runner.zig
│   ├── session.zig
│   └── mod.zig
├── compiler/                      pure source-to-artifact pipelines
├── quirk/                         pure quirk matching and decisions
├── verification/                  proof-artifact consumers
├── runtime/                       shared stateful services
│   ├── resource/
│   ├── queue/
│   ├── cache/
│   ├── sync/
│   ├── lifecycle/
│   ├── memory/
│   ├── device/
│   └── mod.zig
├── backend/
│   ├── ports/                     new narrow outbound interfaces
│   │   ├── factory.zig
│   │   ├── compute.zig
│   │   ├── transfer.zig
│   │   ├── render.zig
│   │   ├── queue.zig
│   │   ├── readback.zig
│   │   ├── capture.zig
│   │   ├── telemetry.zig
│   │   └── mod.zig
│   ├── adapters/
│   │   ├── metal/
│   │   ├── vulkan/
│   │   ├── d3d12/
│   │   ├── delegate/
│   │   └── csl/
│   ├── common/                    native helpers with no policy ownership
│   └── mod.zig
├── evidence/                      new output adapters
│   ├── port.zig
│   ├── trace/
│   ├── receipt/
│   ├── replay/
│   ├── oracle/
│   └── mod.zig
├── composition/                   new construction roots
│   ├── backend_factory.zig
│   ├── runtime_factory.zig
│   ├── cli.zig
│   ├── native.zig
│   ├── dropin.zig
│   ├── plan.zig
│   └── mod.zig
├── cli/                           inbound adapter
├── command/                       inbound parser adapter
├── native/                        inbound WebGPU object/API adapter
├── dropin/                        inbound C ABI adapter
├── plan/                          inbound plan/replay adapter
├── integrations/                  inbound third-party adapters
├── spatial/                       spatial tools; no duplicate compiler/runtime
├── compat/                        declared, tested compatibility only
└── tooling/                       developer/tool I/O only
```

## Directory and file plan

### 1. `runtime/zig/source-layout.json`

**Current role:** architecture manifest with layers, allowed imports, production roots, compatibility contracts, canonical contract declarations, and generated-source contracts.

**Target action:**

- Bump the architecture manifest version.
- Add layers for `app`, `backend-ports`, `backend-adapters`, `evidence`, and `composition`.
- Change the current broad `backend-interface` layer into:
  - `backend-ports`
  - `backend-composition`
  - one layer per concrete adapter
- Remove permission for `runtime` to import broad backend implementation modules.
- Remove permission for `core`, `full`, `native`, `plan`, and `command` to import backend implementation files.
- Make `composition` the only layer that may import concrete adapters.
- Add canonical contract declarations for:
  - `prepared-operation-contract`
  - `execution-report-contract`
  - `evidence-contract`
  - `error-contract`
  - `identity-contract`
  - `ownership-contract`
- Add compatibility-facade entries for every retained old path.
- Keep `dependencyExceptions` and `cycleExceptions` empty.

**Acceptance:**

- zero cycles
- zero forbidden edges
- zero stale exceptions
- every production file assigned one owner and one layer

### 2. `runtime/zig/src/mod.zig`

**Current issue:** it exposes broad package surfaces through a mixture of namespace constants and functions returning module types.

**Target action:**

- Make it a composition/public namespace root only.
- Export stable namespaces with direct `pub const` bindings.
- Do not expose implementation-private backend modules.
- Add `app`, `evidence`, and `composition` namespaces only if they are intended public Zig API.
- Preserve current public imports through a tested compatibility facade during migration.

**Target shape:**

```zig
pub const contracts = @import("contracts/mod.zig");
pub const compiler = @import("compiler/mod.zig");
pub const app = @import("app/mod.zig");
pub const runtime = @import("runtime/mod.zig");
pub const backend = @import("backend/mod.zig");
pub const evidence = @import("evidence/mod.zig");
pub const adapters = struct {
    pub const cli = @import("cli/mod.zig");
    pub const plan = @import("plan/mod.zig");
};
```

### 3. `runtime/zig/src/contracts/`

This is the domain core and should be the most stable directory.

#### Keep and tighten

- `command.zig`
  - remain the sole command taxonomy
  - own command kind, payload union, scope, trace name, and capability requirements
  - prohibit parallel command registries in `command/`, `core/`, `full/`, or backends

- `capability.zig`
  - remain the sole capability registry
  - add compile-time coverage from every command and every backend port

- `artifact.zig`
  - keep artifact identity and immutable target artifact metadata
  - remove filesystem I/O or emitter-specific logic

- `backend.zig`
  - keep `BackendId`, `BackendLane`, selection-result vocabulary, and typed policy values
  - move JSON/file loading out

- `binding.zig`, `texture.zig`, `texture_format.zig`, `shader_abi/**`
  - retain neutral semantic and ABI facts
  - keep backend conversion local to each adapter

#### Add

- `error.zig`
  - canonical execution, validation, unsupported, provider, lifecycle, and evidence error classes
  - migrate definitions from `contracts/execution.zig`, `backend/runtime_types.zig`, and backend-specific duplicate registries

- `exactness.zig`
  - exact bytes, digest equality, tolerance-bounded numeric comparison, semantic oracle, and unsupported comparison classes

- `identity.zig`
  - source identity
  - semantic IR identity
  - target artifact identity
  - prepared-operation identity
  - provider/backend/device identity
  - execution identity

- `ownership.zig`
  - resource owner
  - lifetime phase
  - transfer/borrow semantics
  - release requirements

- `prepared_operation.zig`
  - immutable tagged union for prepared compute, transfer, render, queue, readback, and surface operations
  - contains no backend-native handle except neutral resource IDs
  - contains exact program artifact, bindings, work shape, synchronization, and evidence plan

- `execution_report.zig`
  - one common status, timing, dispatch/submit counts, output identity, lifecycle status, and backend identity contract
  - backend extensions remain separately namespaced

- `evidence.zig`
  - `EvidenceRequirement`
  - `EvidenceCheckpoint`
  - `EvidenceEvent`
  - `EvidenceDisposition`
  - no file-writing implementation

#### Recompose

- `compute.zig`
  - remove `ComputeContext.state: *anyopaque` from the domain contract
  - keep user/request-level compute values
  - move backend call context into `backend/ports/compute.zig`
  - either fold `DispatchReport` into `execution_report.zig` or make it a narrow typed view

- `execution.zig`
  - reduce to stable result/error vocabulary or replace with `error.zig` plus `execution_report.zig`

- `model/model_gpu_types.zig`
  - retain temporarily as an explicit compatibility facade
  - migrate each semantic family to its existing narrow owner
  - delete once all declared consumers use namespaced contracts

### 4. New `runtime/zig/src/app/`

This becomes the actual center of the hexagonal architecture.

- `request.zig`
  - typed application request independent of CLI, JSON, C ABI, Node, or ONNX

- `normalize.zig`
  - convert semantically equivalent inputs to one canonical request

- `validate.zig`
  - capability, shape, ownership, exactness, and lifecycle validation

- `specialize.zig`
  - apply device profile, explicit policy, and accepted quirk decisions
  - no hidden fallback

- `compile.zig`
  - call compiler service and receive immutable `ProgramArtifact`

- `bind.zig`
  - resolve neutral resource IDs and binding layouts
  - no backend descriptor allocation

- `schedule.zig`
  - create synchronization and submission plan
  - declare, but do not execute, backend queue behavior

- `prepare.zig`
  - emit the immutable `PreparedOperation`
  - compute its identity once

- `execute.zig`
  - invoke only backend ports
  - accept an `EvidencePort`
  - return `ExecutionReport`

- `session.zig`
  - own application session lifetime and injected ports
  - no concrete backend construction

- `runner.zig`
  - shared path for immediate, recorded, replayed, direct-plan, and native calls
  - all modes consume the same prepared operation

- `mod.zig`
  - narrow application facade

### 5. `runtime/zig/src/backend/backend_iface.zig`

**Current issue:** one broad vtable owns command execution, dispatch, byte writes, upload configuration, queue modes, timestamp modes, flushing, prewarming, and capture. It is both too broad and leaks runtime types.

**Migration:**

1. Freeze behavior with characterization tests.
2. Add `backend/ports/*.zig`.
3. Implement an adapter wrapper that exposes the old `BackendIface` over the new ports.
4. Migrate consumers one capability at a time.
5. Delete the old vtable after the last declared consumer moves.

**Target ports:**

- `factory.zig`
  - construct a capability set and adapter session

- `compute.zig`
  - execute prepared compute operations

- `transfer.zig`
  - upload, buffer write, and copy

- `render.zig`
  - render, sampler, surface-compatible draw operations

- `queue.zig`
  - submit, wait, flush, synchronization policy

- `readback.zig`
  - mapped or copied output retrieval with explicit ownership

- `capture.zig`
  - diagnostic capture only

- `telemetry.zig`
  - adapter identity and execution observations

Each port is separately optional through an explicit capability set. A compute-only backend must not implement fake render methods.

### 6. `runtime/zig/src/backend/backend_runtime.zig`

**Current issue:** it loads policy, selects a backend, constructs a concrete adapter, proxies every operation, and refreshes telemetry. That combines application policy, composition, and an interface facade.

**Target split:**

- policy loading → `backend/policy_loader.zig`
- provider selection use case → `app/provider_selection.zig`
- concrete construction → `composition/backend_factory.zig`
- session lifetime → `app/session.zig`
- port bundle → `backend/ports/factory.zig`
- telemetry refresh → concrete adapter or evidence adapter

Keep `backend_runtime.zig` temporarily as a facade that delegates to the new session.

### 7. `runtime/zig/src/backend/backend_policy.zig`

**Current issue:** domain policy types are correctly shared from contracts, but this file also performs file lookup, JSON parsing, defaults, validation, and CLI spelling conversion.

**Target split:**

- typed policy values and lane identities remain in `contracts/backend.zig`
- JSON parsing and filesystem search move to `backend/policy_loader.zig`
- CLI name parsing moves to `cli/runtime_cli_args.zig`
- default policies come from versioned config, not a second handwritten switch
- any compiled emergency default must be generated from the same config and hash-bound

### 8. `runtime/zig/src/backend/backend_registry.zig`

**Target action:**

- move concrete adapter imports to `composition/backend_factory.zig`
- keep a registry table describing:
  - backend ID
  - adapter constructor
  - supported ports
  - build availability
- ensure this composition module is the only common file importing Metal, Vulkan, D3D12, and delegates

### 9. `runtime/zig/src/backend/runtime_types.zig`

**Target action:** eliminate it as a broad shared taxonomy.

Move:

- stable status and error values → `contracts/error.zig`
- execution result/timing → `contracts/execution_report.zig`
- queue policy values → `contracts/backend.zig` or `contracts/queue.zig`
- adapter-private state → each concrete adapter
- runtime service state → `runtime/**`

Keep a compatibility facade only while production consumers remain.

### 10. `runtime/zig/src/backend/metal`, `vulkan`, `d3d12`

**Current role:** concrete native implementations.

**Target action:**

- move physically to `backend/adapters/<name>/` only after imports are port-based; a rename before that adds churn without architecture value
- implement the narrow port bundle
- retain native:
  - handles
  - descriptor allocation
  - barriers and transitions
  - command encoders
  - fences/semaphores
  - queue-family behavior
  - backend caches
  - driver workarounds
- remove imports of `core`, `full`, `native`, and broad runtime orchestrators
- consume only:
  - contracts
  - prepared operation/artifact values
  - backend ports
  - backend-local/common helpers
- never import a sibling backend

### 11. Delegate backends

Files such as `dawn_delegate_backend.zig` and any WebKit delegate should move under `backend/adapters/delegate/`.

They must:

- implement the same ports
- report effective provider identity
- retain no special semantic exemption
- never receive DoeRuntime ownership credit from wrapper evidence
- fail when the selected provider is unavailable rather than silently switching

### 12. CSL and spatial execution

Split the current spatial lane into three distinct responsibilities:

- WGSL/TSIR/CSL source lowering remains under `compiler/`
- execution against simulator or hardware becomes `backend/adapters/csl/`
- command-line tools remain under `spatial/` as inbound adapters

`spatial/` must not own a parallel semantic model, compiler pipeline, or receipt definition.

### 13. `runtime/zig/src/runtime/execution.zig`

**Current issue:** it mixes backend construction, execution mode, parsing helpers, configuration mutation, timing, receipt building, and native operation dispatch.

**Target split:**

- `BackendMode`, CLI spellings, and parsing → `cli/runtime_cli_args.zig`
- backend construction → `composition/backend_factory.zig`
- application session → `app/session.zig`
- operation routing → `app/execute.zig`
- prepared operation execution → `runtime/executor.zig`
- timing and lifecycle report assembly → `contracts/execution_report.zig` plus `evidence/receipt/builder.zig`
- public facade retained until all callers migrate

This is the highest-value single-file recomposition after the backend vtable.

### 14. `runtime/zig/src/runtime/execution_receipt.zig`

Move to `evidence/receipt/execution_receipt.zig`.

Rules:

- consume immutable contracts and execution reports
- never choose a backend
- never mutate an operation
- preserve current canonical serialization and hashes through characterization tests

### 15. `runtime/zig/src/runtime/output_oracle.zig`

Move to `evidence/oracle/output_oracle.zig`.

Split:

- exactness and oracle type definitions → `contracts/exactness.zig`
- pure comparison algorithms → `evidence/oracle/compare.zig`
- file loading or CLI output → inbound/tool adapters

### 16. `runtime/zig/src/runtime/trace/**`

Move receipt-bearing and artifact-producing trace modules to `evidence/trace/**`.

Keep only minimal event hooks in runtime:

```zig
pub const EvidencePort = struct {
    context: *anyopaque,
    onPrepared: *const fn (...),
    onExecution: *const fn (...),
    onLifecycle: *const fn (...),
};
```

A no-op implementation is explicit. Evidence failure must be classified separately and must not silently alter semantic execution.

### 17. `runtime/zig/src/runtime/cache`, `device`, `queue`, `lifecycle`, `memory`, `sync`

These remain stateful runtime services.

Rules:

- one resource owner
- no CLI parsing
- no concrete backend imports
- no receipt serialization
- no model of command semantics beyond prepared operations
- narrow context objects instead of broad runtime structs
- explicit cleanup path for every ownership transition

Move duplicated state from `native/cache`, `native/queue`, and `native/lifecycle` into these owners when the behavior is truly shared.

### 18. `runtime/zig/src/core/` and `runtime/zig/src/full/`

These names currently describe compute-focused and full WebGPU feature sets, not the architectural domain core. That is confusing but does not require an immediate rename.

**Phase A:**

- replace `anytype` execution in `core/command_dispatch.zig` and `full/command_dispatch.zig`
- make them preparation routers that emit `PreparedOperation`
- remove imports of `backend/runtime_types.zig`
- make both depend on contracts and app preparation interfaces

**Phase B:**

Move feature logic to:

```text
app/compute/
app/resource/
app/render/
app/surface/
app/diagnostics/
```

Then keep `core/` and `full/` as tested compatibility facades only, or delete them after all consumers migrate.

### 19. `runtime/zig/src/native/`

Native is an inbound adapter implementing the WebGPU object model. It should not be another runtime.

- `native/mod.zig`
  - remain a thin, generated-or-explicit public export facade
  - no policy or state

- `native/api/**`
  - translate WebGPU calls to app requests and runtime handles
  - do not call concrete backend code

- `native/compute/**`
  - build compute requests and use the app runner

- `native/render/**`
  - build render requests and use the app runner

- `native/resource/**`
  - own API object wrappers and handles only
  - delegate allocation/lifetime semantics to runtime resource services

- `native/queue/**`
  - translate queue calls
  - delegate scheduling/sync to runtime queue services and QueuePort

- `native/cache/**`
  - migrate shared caches to runtime
  - retain only adapter-local lookup if necessary

- `native/shader/**`
  - call compiler service
  - store `ProgramArtifact`, not emitter-private structures

- `native/lifecycle/**`
  - translate callbacks and object release
  - shared lifecycle state belongs to runtime

Every native subdirectory requires a parity test proving that direct, recorded, and replayed forms produce the same prepared-operation identity.

### 20. `runtime/zig/src/dropin/`

Drop-in is a C ABI adapter.

- `dropin_router.zig`
  - remain the sole routing entry
  - delegate to native/app composition

- `dropin_abi_procs.zig`
  - generate from the authoritative procedure manifest where practical
  - do not manually duplicate symbol ownership and implementation routing

- `dropin_proc_manifest.zig`
  - become the one procedure registry

- `dropin_runtime_config.zig`
  - parse adapter configuration only
  - no execution semantics

- `dropin_browser_shared_memory.zig`
  - remain an isolated browser-specific adapter
  - no broader browser claim

- `wgpu_dropin_lib.zig` and `root.zig`
  - composition/export roots only

### 21. `runtime/zig/src/plan/`

Plan is an inbound format, not an alternate runtime.

- `dawn_plan_types.zig`
  - external schema/types only

- `plan_validation.zig`
  - validate external plan structure

- new `plan_normalize.zig`
  - convert to canonical app requests

- new `plan_adapter.zig`
  - call the app runner

- `doe_plan_executor.zig`
  - strip parsing, backend construction, trace ownership, and execution semantics
  - become orchestration around the plan adapter

- `webgpu_plan_executor_core.zig`
  - stop implementing a parallel semantic executor
  - use the same prepared-operation runner

- `synthetic_assets.zig`
  - test/fixture support only; never production fallback

### 22. `runtime/zig/src/command/`

Command is an inbound parser.

- `command_json*.zig`
  - parse JSON only
  - produce canonical `contracts.Command`

- `command_kind.zig`
  - remove duplicate command taxonomy
  - reference `contracts/command.zig`

- `command_parse_*.zig`
  - retain format-specific parsing
  - no runtime or core imports

- `command_parse_helpers.zig`
  - split by parsing responsibility if it remains multi-domain
  - avoid a general catch-all helper

- `command_stream.zig`
  - stream framing and ordering only
  - hand normalized commands to the app adapter

Update the architecture manifest so `command` may import only contracts and command-local parser code.

### 23. `runtime/zig/src/cli/`

CLI is I/O and composition.

- `runtime_cli_args.zig`
  - own all command-line spelling and parsing

- `runtime_cli_inputs.zig`
  - file/stdin input only

- `runtime_cli_artifacts.zig`
  - render/write result artifacts only

- `runtime_cli.zig`
  - reduce to command selection and calls into `composition/cli.zig`
  - move backend selection, execution, and policy decisions out

- `doe_plan_executor_cli.zig`, `module_runner_cli.zig`
  - remain thin composition roots

- `entrypoints/*.zig`
  - remain tiny process roots

### 24. `runtime/zig/src/compiler/`

Keep a real compiler pipeline:

```text
frontend → semantic model → IR → transform → proof → emitter → ProgramArtifact
```

Actions:

- make every target emitter return the same `contracts.ProgramArtifact`
- prohibit concrete backend imports
- move host/shader shared ABI facts into `contracts/shader_abi`
- rename or clarify `compiler/wgsl/runtime/` so it is not confused with GPU execution runtime
- keep TSIR and CSL lowering under compiler
- let concrete adapters consume artifacts, not emitter internals
- preserve exact semantic digests through every refactor

### 25. `runtime/zig/src/quirk/`

`quirk/runtime.zig` should be recomposed because it contains several responsibilities.

Target files:

- `types.zig` or contracts-owned types
- `parse.zig`
- `match.zig`
- `score.zig`
- `decision.zig`
- `apply.zig`
- `receipt.zig` only if it is a pure decision record, otherwise evidence owns it

No quirk module may import a backend implementation or mutate runtime state directly. It returns an explicit decision consumed while preparing the operation.

### 26. `runtime/zig/src/verification/lean_proof.zig`

Split into:

- `artifact.zig`
- `provenance.zig`
- `registry.zig`
- `lookup.zig`
- `mod.zig`

This remains a proof-artifact consumer. It does not become a runtime policy engine. Application preparation asks whether a named obligation is satisfied; verification returns a typed result.

### 27. `runtime/zig/src/integrations/onnxruntime/`

Treat ONNX Runtime as an inbound application adapter.

- translate ONNX execution-provider requests into application requests
- consume stable app facade and contracts
- do not import Metal/Vulkan/D3D12 implementations
- provider-specific construction occurs in composition
- qualification remains independently gated

### 28. `runtime/zig/src/spatial/`

Keep only:

- CSL bundle/tool input adapters
- simulator/hardware invocation adapters
- output translation

Move reusable lowering into compiler and execution into the CSL backend adapter.

### 29. `runtime/zig/src/evidence/` — new

- `port.zig`
  - stable observer interface

- `trace/`
  - deterministic event stream and hash chain

- `receipt/`
  - execution, lifecycle, provider, and release-evidence receipts

- `replay/`
  - replay identity and validation

- `oracle/`
  - exact and tolerance-bound comparison implementations

Rules:

- consumes the same prepared operation and report used by execution
- no alternate kernels
- no provider selection
- no hidden fallback
- evidence failure is explicit and separately classified

### 30. `runtime/zig/src/composition/` — new

This is where the architecture becomes genuinely hexagonal.

- `backend_factory.zig`
  - imports all concrete adapters
  - selects one only under explicit policy

- `runtime_factory.zig`
  - constructs runtime services and port bundle

- `cli.zig`
  - wires CLI adapter to app runner and evidence adapter

- `native.zig`
  - wires native WebGPU adapter

- `dropin.zig`
  - wires C ABI adapter

- `plan.zig`
  - wires plan adapter

No other ordinary module may import multiple concrete backends.

## Migration order

### Phase 0: freeze behavior

Capture:

- public Zig exports
- C ABI symbols
- command parse fixtures
- WGSL semantic and target artifact digests
- representative Metal/Vulkan/D3D12 outputs
- trace and receipt identities
- lifecycle behavior
- clean/incremental build times

No structural change proceeds without characterization evidence.

### Phase 1: make the desired graph executable

Update `source-layout.json`, architecture analyzer tests, and generated reports before moving implementation. Initially permit explicit temporary facade edges; name each consumer and removal condition.

### Phase 2: add contracts and ports without changing behavior

Add `PreparedOperation`, `ExecutionReport`, identity, ownership, exactness, evidence, and narrow backend ports. Wrap the existing backend interface behind these ports.

### Phase 3: kernel-dispatch vertical slice

Migrate exactly one path:

```text
command JSON / native call / plan
→ ApplicationRequest
→ PreparedComputeOperation
→ ComputePort
→ existing Metal/Vulkan/D3D12 implementation
→ ExecutionReport
→ existing trace/receipt
```

Require exact output, error, trace, lifecycle, and identity parity.

### Phase 4: split the backend interface

Migrate in this order:

1. compute
2. queue
3. transfer
4. readback
5. capture
6. render
7. telemetry
8. factory/lifecycle

Delete each old vtable method immediately after its last consumer migrates.

### Phase 5: extract application orchestration

Move behavior out of `runtime/execution.zig`, plan executors, native compute/render modules, and CLI. All entrypoints use the same app runner.

### Phase 6: extract the evidence plane

Move trace, receipt, replay, and oracle implementations under `evidence/`. Prove that enabling or disabling an evidence adapter does not change semantic output or provider choice.

### Phase 7: de-duplicate runtime state

Consolidate resource, queue, cache, sync, lifecycle, and memory state. Native becomes object/API adaptation; backends own native resources; runtime owns shared services.

### Phase 8: migrate remaining commands

Buffer upload, copies, pipeline creation, render, surface, diagnostics, and async operations follow the kernel-dispatch pattern.

### Phase 9: finish spatial and integration adapters

Route ONNX and CSL through the same application contracts and ports. Keep their claims separately gated.

### Phase 10: remove facades

Delete old paths only after:

- no production consumer remains
- the compatibility contract’s removal condition is met
- public API and ABI gates pass
- artifact and trace parity passes

## Blocking acceptance gates

Every migration phase must pass:

```bash
zig fmt
zig build test
zig build test-core
zig build test-full
zig build test-wgsl
zig build import-fence
zig build source-layout
zig build line-limits
python3 tools/check_source_layout.py
python3 tools/generate_architecture_reports.py --check
```

Additionally require:

- zero import cycles
- zero forbidden edges
- no new dependency exceptions
- no concrete backend imports outside composition and backend-local modules
- exact canonical command round-trip
- prepared-operation parity across immediate, recorded, direct, and replay paths
- output oracle parity
- first-failure parity
- trace and receipt identity parity
- lifecycle cleanup parity
- C ABI symbol parity
- public Zig export parity

## What not to do

- Do not move files merely to make the tree look hexagonal.
- Do not create one giant `ports.zig`.
- Do not replace the broad backend vtable with another broad port bundle.
- Do not make every backend implement unsupported methods as no-ops.
- Do not let evidence code choose providers or alter execution.
- Do not let plans, native calls, and command JSON retain separate semantic executors.
- Do not rename `core` and `full` before the common application path exists.
- Do not preserve internal import paths with untracked facades.
- Do not infer architecture quality from file count or line count.
- Do not treat a cycle-free graph as sufficient if the allowed dependency matrix still permits architectural backflow.

## Final success condition

The migration is complete when every supported entrypoint produces the same immutable `PreparedOperation`, every concrete provider is reachable only through narrow ports and a composition root, shared runtime state has one owner, and trace/receipt/replay code observes the exact operation and result without influencing them.
