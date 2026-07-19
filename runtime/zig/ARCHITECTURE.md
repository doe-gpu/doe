# Doe Zig Architecture

This document tracks the current Zig runtime topology in `runtime/zig/src`.
It replaces the old `parser/dispatch/executor` module naming model.

## Runtime goals

- deterministic command selection and execution
- explicit unsupported taxonomy (no silent fallback)
- pipeline/trace/replay parity for audit and debugging
- config-driven behavior for benchmark and gate contracts

## Current module topology

Core decision/runtime lane:

- `runtime/zig/src/contracts/model/model.zig`
  - typed contract enums/structs for quirks, commands, and runtime status
- `runtime/zig/src/quirk/quirk_json.zig`
  - strict quirk JSON ingestion (accessed via `quirk/mod.zig`)
- `runtime/zig/src/command/command_json.zig`
  - strict command JSON ingestion
- `runtime/zig/src/quirk/runtime.zig`
  - deterministic quirk matching + precedence selection
- `runtime/zig/src/runtime/execution.zig`
  - execution mode orchestration (`trace` vs `native`)
- `runtime/zig/src/cli/entrypoints/main.zig`
  - CLI boundary and artifact wiring

Trace/replay lane:

- `runtime/zig/src/runtime/trace/trace.zig`
  - trace row + trace-meta emission and hash-chain generation
- `runtime/zig/src/runtime/trace/replay.zig`
  - replay validation against row/meta contract invariants

WebGPU native execution lane:

- `runtime/zig/src/compat/webgpu_ffi.zig`
  - backend lifecycle (instance/adapter/device/queue), capability probing, queue wait/sync behavior
- `runtime/zig/src/core/abi/`
  - C API types, descriptors, callbacks, and proc-table contracts
- `runtime/zig/src/core/abi/wgpu_loader.zig`
  - dynamic proc loading and callback helpers
- `runtime/zig/src/core/resource/wgpu_resources.zig`
  - buffer/texture/shader/pipeline resource management
- `runtime/zig/src/full/command/wgpu_commands.zig`
  - command execution glue (sandbox validation, core/full dispatch routing)
- `runtime/zig/src/full/render/`
  - render pass/bundle/resource/type-specific surfaces
- `runtime/zig/src/core/abi/procs/`
  - domain-specific proc tables (P0/P1/P2 surfaces, texture/surface/async/capability APIs)

## Data flow

1. Input load
- CLI arguments resolve quirk + command artifacts.
- JSON ingestion modules parse into typed model contracts.

2. Deterministic selection
- `runtime.zig` filters candidate quirks by profile.
- per-command matching chooses one action with deterministic precedence.

3. Execution
- `execution.zig` routes command handling.
- trace mode emits deterministic decision artifacts only.
- native mode executes through WebGPU proc surfaces with explicit status mapping.

4. Observability
- trace rows carry command/op metadata and hash-chain links.
- trace-meta carries run-level timing, status counts, and terminal hash.
- replay validates deterministic continuity.

## Lean boundary

- Lean remains a verification producer and does not execute hot path logic at runtime.
- Zig consumes verification-relevant fields (`verificationMode`, `proofLevel`) and emits obligations in trace artifacts.
- Proof-driven elimination is implemented by deleting proven runtime branches and hoisting conditions into artifacts/config.

## Extension discipline

- Add WebGPU procedure groups under `core/abi/procs/` and behavior under the
  owning `core/` or `full/` feature directory.
- Keep capability probing and unsupported taxonomy explicit.
- Route all runtime-visible behavior changes through config + docs + status updates in the same change.

## Gate expectations

- `zig fmt` on changed Zig files
- `zig build test` for affected modules
- schema/correctness/trace gates must remain green for release paths
