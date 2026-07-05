# Doe Zig Style Guide

This guide is the Zig style contract for `zig`.

## Core principles

- Prefer explicit typed contracts over inferred behavior.
- Keep runtime decisions deterministic and traceable.
- Fail fast on invalid/unsupported inputs with actionable errors.
- Keep hot-path execution allocation-light after initialization.

## Repository conventions

- Anchor shared command/profile contracts in `model.zig`. When they grow into
  independent domains, shard them into feature-scoped modules and re-export
  through `model.zig` until callers can be migrated safely.
- Put quirk parsing in `quirk/quirk_json.zig` and command parsing in `command_json.zig`.
- Keep deterministic selection logic in `runtime.zig`.
- Keep execution orchestration in `execution.zig`.
- Keep pipeline/trace/replay behavior in `trace.zig` and `replay.zig`.
- Anchor WebGPU proc/table contracts in `wgpu_types.zig` and loader glue in
  `wgpu_loader.zig`. When those files become broad hubs, split contracts by
  feature and keep the old file as a compatibility re-export surface.
- Add new API clusters as feature-scoped `wgpu_*_procs.zig` modules.

## Architectural decoupling

- Treat directories as subsystem boundaries, not just file buckets.
- Prefer dependency direction: contracts -> helpers -> subsystem
  implementation -> facade/orchestration.
- Root-level `src/*.zig` files should be thin facades, entrypoints, or stable
  contract barrels. Do not grow new feature logic there when it can live in a
  feature subtree.
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
- Keep `doe_wgsl` self-contained except for explicit shared proof/contracts.
- Keep `quirk` limited to quirk logic plus shared contracts/proof inputs; it
  should not depend on backend execution modules.
- Prefer narrow context/state types over monolithic runtime structs when
  crossing subsystem boundaries.
- Avoid introducing new import cycles. If an import would create one, extract a
  smaller contract/state module and depend on that instead.
- When splitting a high-fan-in file, move definitions first, keep a
  compatibility re-export facade, and migrate callers incrementally rather than
  forcing a big-bang rename.
- Shared types should live with the subsystem that owns their semantics, not in
  whichever orchestration file currently imports them most often.
- New implementation code should not import compatibility barrels such as
  `model_transfer_types.zig`,
  `model_runtime_types.zig`, `model_webgpu_types.zig`, `wgpu_types.zig`, or
  `webgpu_ffi.zig`. Use the narrow source modules directly; keep the
  compatibility barrels for export and transition surfaces only.
- `doe_native_types.zig` and `doe_native_helpers.zig` are compatibility
  barrels only. Implementation code should import
  `doe_native_object_types.zig`, `doe_native_shared_types.zig`,
  `doe_native_command_types.zig`, `doe_native_object_helpers.zig`, and
  `doe_native_runtime_helpers.zig` directly; keep `doe_native_exports.zig`
  for cross-shard native C ABI declarations.
- When a caller only needs shared texture/layout values, import
  `model_texture_value_types.zig`. When it only needs shader-stage or
  binding/sample/access values, import `model_binding_value_types.zig`.
  Reserve `model_gpu_types.zig` for compatibility or transition callers that
  genuinely need both value families at once.
- Prefer `model_resource_types.zig` for upload/copy/barrier payloads and
  `model_compute_types.zig` for dispatch/kernel-binding payloads instead of
  routing through the compatibility `model_transfer_types.zig` barrel.
- Prefer `model_texture_types.zig` for texture read/write/query payloads,
  `model_surface_control_types.zig` for surface lifecycle/configuration
  payloads, and `model_async_types.zig` for async-diagnostics or map-async
  payloads instead of routing through the compatibility `model_surface_types.zig`
  barrel.
- `wgpu_base_types.zig` and `wgpu_descriptor_types.zig` are broad
  compatibility barrels. Implementation code should import
  `wgpu_core_base_types.zig`, `wgpu_feature_base_types.zig`,
  `wgpu_texture_base_types.zig`, `wgpu_binding_base_types.zig`,
  `wgpu_callback_descriptor_types.zig`, `wgpu_copy_descriptor_types.zig`,
  `wgpu_pipeline_descriptor_types.zig`, `wgpu_execution_types.zig`,
  `wgpu_record_types.zig`, and `wgpu_state_types.zig` directly as needed.

## File size

- 999 lines max per source file in `runtime/zig/src/`.
- Shard before exceeding this limit, not after.
- Exceptions, when unavoidable, are tracked in the `ALLOWLIST` in
  `runtime/zig/tools/check_line_limits.py` and each entry must name a
  specific sharding follow-up in the relevant live status shard. Treat
  allowlist entries as tracked debt, not precedent for new files.
- Split by cohesive functionality (e.g. `pipeline_cache.zig`), not by type (e.g. `helpers.zig`).
- Keep related code together; splitting must not scatter a single concern.

## Formatting

- Run `zig fmt` on every changed file before commit.
- `zig fmt` compliance is a blocking check; do not commit unformatted Zig.

## Imports

- `std` and `builtin` first.
- Then local modules, with `model.zig` before domain-specific imports.
- Group domain imports by subsystem (e.g. backend modules together).

```zig
const std = @import("std");
const builtin = @import("builtin");
const model_texture = @import("model_texture_value_types.zig");
const model_binding = @import("model_binding_value_types.zig");
const model_compute = @import("model_compute_types.zig");
const wgpu_core = @import("core/abi/wgpu_core_base_types.zig");
const wgpu_texture = @import("core/abi/wgpu_texture_base_types.zig");
const wgpu_pipeline = @import("core/abi/wgpu_pipeline_descriptor_types.zig");
const native_object_types = @import("doe_native_object_types.zig");
const native_object_helpers = @import("doe_native_object_helpers.zig");
const backend_runtime = @import("backend/backend_runtime.zig");
const backend_ids = @import("backend/backend_ids.zig");
```

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

- No bare numeric literals in runtime code.
- Use named `UPPER_SNAKE_CASE` comptime constants or config values.
- Place constants at file top, after imports.
- Domain-shared constants belong in the narrow contract module that owns their
  semantics, such as `model_texture_value_types.zig`,
  `model_binding_value_types.zig`, `wgpu_core_base_types.zig`, or
  `wgpu_texture_base_types.zig`.
- Module-specific constants stay in the module that uses them.
- If a value appears in more than one file, it must have a single source of truth.

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

## Errors and diagnostics

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

## Testing

- Tests are inline `test` blocks in the source file they cover.
- Test names are descriptive behavior strings: `test "vendor comparison ignores case"`.
- Use `std.testing.expect` and `std.testing.expectEqual` for assertions.
- Prefer `std.testing.allocator` for tests that exercise allocation-owning code
  unless the allocator choice itself is part of the behavior under test.
- Run `zig build test` for affected runtime modules.
- Verify replay/trace gate compatibility for runtime-visible changes.
- For WebGPU API-surface changes, update config coverage + benchmark contracts in the same change.
