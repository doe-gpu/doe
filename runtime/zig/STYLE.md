# Doe Zig Style Guide

This guide is the Zig style contract for `zig`.

## Core principles

- Prefer explicit typed contracts over inferred behavior.
- Keep runtime decisions deterministic and traceable.
- Fail fast on invalid/unsupported inputs with actionable errors.
- Keep hot-path execution allocation-light after initialization.
- Give every semantic fact one authoritative owner and every subsystem one
  narrow public surface.
- Eliminate duplicate registries, policy maps, profile unions, errors, artifact
  fields, and conversion taxonomies before optimizing file count.

## Invariant registry

These identifiers are normative and should be named by reviews, regression
tests, and receipts when a change touches the corresponding boundary.

| ID | Invariant | Enforcement surface |
| --- | --- | --- |
| `INV-OWNER-001` | Shared behavior lives with the narrowest subsystem that owns its semantics; dependency direction remains one-way. | `tools/check_source_layout.py`, `tools/check_core_import_fence.py`, import tests |
| `INV-PLAN-002` | Immediate, recorded, replayed, direct, and indirect execution derive from one prepared-operation contract. | affected executor parity tests, trace/replay gates |
| `INV-RESOURCE-003` | Every resource has one explicit owner and every ownership transition has one cleanup path. | allocator-backed tests, lifecycle and failure-path tests |
| `INV-RECEIPT-004` | Structural refactors preserve the canonical behavior receipt and first failure boundary. | trace determinism, replay, semantic digest, and workload-oracle tests |
| `INV-FACADE-005` | Module roots and compatibility facades aggregate, normalize, delegate, or translate errors; they do not own independent domain behavior. | `source-layout.json`, `tools/check_source_layout.py`, exercised facade tests |
| `INV-REGISTRY-006` | Each command, capability, error class, artifact identity, and timing field has one authoritative registry or contract. | compile-time coverage, schema gates, duplicate-declaration inventory |
| `INV-CONTEXT-007` | Promoted execution boundaries use explicit context, request, and report types rather than `anytype` dependency hiding. | affected-path compile and parity tests |
| `INV-ARCH-008` | Every production module has one declared owner, layer, and special role, with zero forbidden dependency edges or cycles. | versioned `source-layout.json`, architecture graph gate |

No prose-only waiver satisfies an invariant. If the named global gate cannot
observe a changed behavior, the affected subsystem must add a focused
characterization or parity test in the same change.

## Repository conventions

- Shared command/profile contracts belong to `contracts/`; parsing belongs to
  the subsystem that owns the input language.
- Quirk selection belongs to `quirk/`; execution orchestration, trace, and
  replay belong to `runtime/`; WebGPU ABI contracts belong to `core/abi/`.
- The current ownership directories and compatibility facades are generated in
  `src/README.md` from `source-layout.json`. Do not duplicate that changing
  module inventory in this guide.

`source-layout.json` is the architecture manifest, not merely a directory
inventory. Its architecture-aware version must own layers, import permissions,
special roles, compatibility-facade lifecycle, generated sources, and any
cohesive-module size justification. Do not create a second policy file for
those facts.

## Architectural decoupling

- Treat directories as subsystem boundaries, not just file buckets.
- Prefer dependency direction: contracts -> helpers -> subsystem
  implementation -> facade/orchestration.
- `src/mod.zig` is the only production Zig file allowed directly under `src/`.
  `source-layout.json` assigns every implementation to an ownership directory,
  and `tools/check_source_layout.py` enforces that boundary.
- `core` must remain one-way with respect to `full`. If shared behavior is
  needed, extract it into `core`, `backend/common`, or a new contract module
  rather than importing upward.
- Backend-specific code must not import sibling backends directly. Cross-backend
  sharing belongs in `backend/common`.
- Non-backend implementation files must not import `backend/metal/*`,
  `backend/vulkan/*`, or `backend/d3d12/*` directly. Route those dependencies
  through backend-owned seam modules under `src/backend/`.
- Non-backend implementation files must reach backend-specific behavior through
  backend-owned seam modules such as `backend/dropin_*.zig`, not by importing
  `backend/metal/*`, `backend/vulkan/*`, or `backend/d3d12/*` directly. The
  import fence enforces this boundary.
- Keep `compiler/wgsl` self-contained except for explicit shared
  proof/contracts.
- Keep `quirk` limited to quirk logic plus shared contracts/proof inputs; it
  should not depend on backend execution modules.
- Prefer narrow context/state types over monolithic runtime structs when
  crossing subsystem boundaries.
- Avoid introducing new import cycles. If an import would create one, extract a
  smaller contract/state module and depend on that instead.
- When splitting a high-fan-in file, move definitions first and retain a
  compatibility facade only when an exercised compatibility contract requires
  it. Every retained facade must be declared in `source-layout.json`.
- Shared types should live with the subsystem that owns their semantics, not in
  whichever orchestration file currently imports them most often.
- New implementation code must not import `compat/`; the compatibility surface
  is for compatibility tests and declared consumers only.
- Native implementation code should import the narrowest support, contract,
  value-type, or ABI shard that owns the required symbols. Broad aggregation
  modules are compatibility/facade surfaces, not default implementation
  dependencies.

## Module roots and facades

- Module roots may re-export contracts, normalize public inputs, delegate to
  feature owners, and translate errors at the public boundary.
- Module roots must not own mutable diagnostic state, semantic transforms,
  backend realization, resource state machines, or substantive feature tests.
- Compatibility facades may contain aliases and delegation required by a
  declared consumer. They must not introduce independent policy or execution
  semantics.
- Every compatibility facade must be declared in `source-layout.json` and
  name its external consumer, reason, owner, consumer-facing test, and removal
  condition.
- When moving implementation out of a root or facade, definitions move first;
  the facade remains only until its declared consumers migrate.

## File size

The architecture-aware policy in `source-layout.json` is active:

- 800 lines is an advisory review signal;
- more than 1,200 lines requires an explicit cohesive-module justification in
  the architecture manifest;
- 1,500 lines is the hard maximum for handwritten production source;
- generated specification or table files use a separately declared,
  reproducible generation contract;
- no size-driven split is accepted unless every resulting module has a named
  semantic responsibility.

The thresholds are not targets. A file that owns multiple state machines,
artifact kinds, input languages, or execution phases must split even below the
advisory signal. Split by cohesive functionality, keep related code together,
and do not create a module whose only identity is satisfying a line limit.

File-count reduction and size distribution are campaign observations, not
architectural correctness gates.

## Semantic inventory decisions

Architecture analysis assigns every production file one decision:

- **Keep**: executable or package root, ABI/FFI boundary, generated
  specification, stable shared contract, or independently meaningful
  algorithm.
- **Merge**: one production importer, no independent contract or test identity,
  same owner as its consumer, and only forwarding declarations, private
  constants, or a tiny private record.
- **Elevate**: a semantic fact used across layers currently lives inside one
  implementation; move it to the neutral owner.
- **Recompose**: one file owns multiple state machines, policies, contexts,
  artifact kinds, or pipeline phases; reorganize by those responsibilities.
- **Delete**: unreachable, superseded, duplicated, or an unconsumed
  compatibility facade.

Physical size, fan-in, fan-out, and co-change frequency are diagnostic evidence
for these decisions. None decides the outcome alone.

## Canonical contract families

Resolve duplicate sources of truth in this order:

1. command kinds, payloads, scope, parser names, and trace names;
2. capabilities and feature identities;
3. error and unsupported classifications;
4. artifact identity and hash fields;
5. timing and dispatch-result semantics;
6. texture-format and binding mappings;
7. backend selection and fallback policy.

Each family has one neutral typed owner. Backend-specific conversion and native
control flow remain local to the backend. Prefer an explicit tagged union plus
complete metadata table before considering type generation.

## Formatting

- Run `zig fmt` on every changed file before commit.
- `zig fmt` compliance is a blocking check; do not commit unformatted Zig.

## Imports

- `std` and `builtin` first.
- Then local modules, with shared contracts before domain-specific imports.
- Group domain imports by subsystem (e.g. backend modules together).

- Prefer small feature-scoped modules over catch-all utility files.
- Prefer importing feature-local contract/state modules over whole runtime
  orchestrators.
- Before importing a broad hub such as a facade or backend runtime, check
  whether a narrower contract module is the real dependency.

## Naming

- Types and enums: `PascalCase`
- Functions: `camelCase`
- Variables and fields: `snake_case`
- Compile-time constants: `UPPER_SNAKE_CASE`
- File names: `snake_case.zig`
- Doe runtime files stay `snake_case.zig` even when a file is centered on one
  primary type; do not introduce `PascalCase.zig` files in `runtime/zig/src/`.

## Constants and magic numbers

- Inline `0`, `1`, simple index arithmetic, and language-level sentinels when
  they are the clearest expression of local mechanics.
- Name domain, ABI, policy, threshold, size, retry, and timing values.
- Use named `UPPER_SNAKE_CASE` comptime constants or config values.
- Place constants at file top, after imports.
- Domain-shared constants belong in the narrow contract module that owns their
  semantics, such as `model_texture_value_types.zig`,
  `model_binding_value_types.zig`, `wgpu_core_base_types.zig`, or
  `wgpu_texture_base_types.zig`.
- Module-specific constants stay in the module that uses them.
- If a value appears in more than one file, it must have a single source of truth.

## Canonical serialization

- Each schema-owned artifact kind owns its canonical field walk and validation.
- Shared byte, number, string, and key emission belongs in one narrow canonical
  writer module.
- Do not combine unrelated artifact walkers in a catch-all digest module only
  because they share SHA-256 or JSON emission.
- Canonicalization refactors must preserve exact bytes, semantic digests, error
  classification, and allocation cleanup through characterization tests.

```zig
const QUEUE_SYNC_RETRY_LIMIT: u32 = 3;
const QUEUE_SYNC_RETRY_BACKOFF_NS: u64 = 1_000_000;
pub const TIMESTAMP_BUFFER_SIZE: u64 = 16;
```

## Control flow

- Prefer `switch` on enums over long `if` ladders.
- Use early returns for invalid states.
- Keep fallback behavior explicit and auditable.
- Do not introduce silent capability switching.

## Prepared operation parity

- Resolve policy, bindings, work shape, entry point, specialization, and
  fallback eligibility before selecting an executor.
- Immediate, recorded, replayed, direct, indirect, and backend-specific paths
  consume the same immutable prepared-operation contract.
- Executor adapters may differ only in submission, resource retention,
  completion, readback scheduling, and evidence capture.
- An executor must not reinterpret bindings, invent defaults, change dispatch
  shape, or select a different shader or pipeline.
- Every executor split or merge requires a parity test that changes one plan
  field and proves all applicable adapters observe the same change.

Promoted execution interfaces use named types such as `ComputeContext`,
`DispatchRequest`, and `DispatchReport`. `anytype` remains acceptable for
private, local, compile-time-generic helpers; it is forbidden where it hides
the dependencies or output contract of a subsystem or promoted execution path.

## Errors and diagnostics

- Compiler lowering must emit either a valid typed semantic value or a typed
  rejection with source/node location and reason. Placeholder scalar types,
  shapes, or handles are forbidden in promotable semantic artifacts.
- Artifacts carrying semantic rejections are diagnostic-only and cannot enter
  code generation, parity promotion, or claim-bearing workloads.
- Return explicit error unions (`!T`) for recoverable failures.
- Keep unsupported behavior explicit (`unsupported` taxonomy), never silent no-op.
- Include actionable context: what was expected, what was received.
- Route runtime observability through pipeline/trace/trace-meta contracts.
- No ad-hoc `std.debug.print` in runtime paths; use structured trace output.
- Guarded debug output (e.g. `DOE_WGPU_TIMESTAMP_DEBUG`) is acceptable for investigation aids, not for production paths.
- When a parameter is required by an interface or callback but intentionally
  unused, suppress it explicitly with `_ = param;` rather than relying on broad
  placeholder naming.

## Comments

- Comments explain why, not what.
- Do not add comments that restate the code.
- Use `///` doc comments for public function/type intent.
- Inline comments are for preconditions, control-flow rationale, or non-obvious constraints.
- Do not add TODO/FIXME inline; track follow-ups in the status log (`docs/status.md`, with dated entries in the current `docs/status/*.md` shard).

## Memory

- Functions that allocate must take an explicit allocator parameter unless the
  allocator is already owned by the receiving struct/context.
- Use explicit allocator ownership.
- Structs that own heap-backed state should store the allocator needed to
  release that state and provide an explicit `deinit` path.
- Scope temporary allocations with `defer` cleanup.
- Use `errdefer` for partial initialization rollback and multi-step allocation
  or acquisition paths that can fail after earlier resources are acquired.
- Place `defer`/`errdefer` immediately after the acquisition they clean up when
  the pairing is not obvious from a tighter local scope.
- Keep long-lived caches explicit in owning structs.
- Prefer arena allocators only for clearly bounded lifetimes such as one parse,
  one request, or one artifact build; do not use arenas to hide long-lived
  ownership.
- Resource contracts should make ownership state explicit where a value crosses
  a subsystem boundary: `borrowed`, `scope_owned`, `submit_owned`,
  `transferred`, or `retained`.
- Ownership transitions belong to the resource owner, not to convenience
  callers. Each transition must have one success cleanup path and one tested
  failure cleanup path.

## FFI and C interop

- Define C function pointer types as `pub const Fn<Name> = *const fn (...) callconv(.c) <ReturnType>`.
- Collect function pointers into a `Procs` struct in `wgpu_types.zig`.
- Required procs are non-optional fields. Optional/conditional procs use `?` wrapper.
- Load required procs with `loadProc()` (error on missing symbol). Load optional procs with `loadOptionalProc()` (returns null on missing symbol).
- Check optional proc availability before call: `if (procs.someFn) |fn| fn(...) else return error.Unsupported`.
- C callbacks use `callconv(.c)` and cast `?*anyopaque` userdata to known state structs via `@ptrCast(@alignCast(...))`.
- Suppress unused callback parameters with `_ = param;`.
- Keep `@cImport` isolated to support or backend-boundary modules when
  unavoidable; do not spread ad-hoc C imports through general runtime logic
  when an existing typed seam or ABI module already owns that contract.

```zig
// Type alias
pub const FnWgpuCreateInstance = *const fn (?*anyopaque) callconv(.c) WGPUInstance;

// Proc struct
pub const Procs = struct {
    wgpuCreateInstance: FnWgpuCreateInstance,           // required
    wgpuDeviceHasFeature: ?FnWgpuDeviceHasFeature,     // optional
};

// Callback
fn onQueueWorkDone(status: types.WGPUQueueWorkDoneStatus, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const state = @as(*types.QueueSubmitState, @ptrCast(@alignCast(userdata1.?)));
    state.done = true;
    _ = status;
}
```

## Determinism and trace

- Identical inputs/config must produce stable decision and trace sequences.
- Preserve hash-chain invariants in trace rows/meta.
- Include enough metadata to reproduce selection and execution outcomes.

## Structural refactor receipts

Before moving runtime or compiler behavior, capture the observable contract for
the affected path. The retained evidence must cover every applicable field:

- resolved policy and runtime identity;
- semantic or prepared-operation plan;
- operation and submission order;
- shader, pipeline, and specialization identity;
- resource acquisition, transfer, retention, and release events;
- output identity or oracle verdict;
- diagnostic classification and first failure boundary.

After the move, compare the receipt, semantic digest, trace chain, output
oracle, and performance class. Remove a compatibility facade only after its
declared consumers use the new owner and the parity evidence remains green.

Before a recomposition campaign begins, bind the baseline to one commit and
retain:

- public Zig modules and declarations reachable through `@import("doe")`;
- exported C ABI symbols;
- command parsing and normalized command representations;
- compiler semantic and target-output digests;
- traces, terminal hashes, replay results, and receipt identities;
- backend capabilities and unsupported classifications;
- representative backend outputs;
- clean and incremental compilation measurements, promoted hot-path medians,
  and binary sizes.

Every structural change is classified as exact equivalence, an explicitly
approved contract change, or failure. Public API changes require a manifest
diff; no rename, move, or split may silently change an error name, import path,
shader output, fallback decision, synchronization behavior, or receipt field.

## Testing

- Use inline `test` blocks for private, pure, module-local behavior.
- Use dedicated external tests for integration, ABI, backend execution, golden
  artifacts, cross-module characterization, and cross-backend parity.
- Shared fixtures belong in one domain-local fixture module when multiple tests
  genuinely share setup.
- Generate suite imports from the owned test inventory instead of maintaining
  parallel manual aggregator lists.
- Test names are descriptive behavior strings: `test "vendor comparison ignores case"`.
- Use `std.testing.expect` and `std.testing.expectEqual` for assertions.
- Prefer `std.testing.allocator` for tests that exercise allocation-owning code
  unless the allocator choice itself is part of the behavior under test.
- Run `zig build test` for affected runtime modules.
- Verify replay/trace gate compatibility for runtime-visible changes.
- For WebGPU API-surface changes, update config coverage + benchmark contracts in the same change.
