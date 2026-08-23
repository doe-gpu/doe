# Doe Zig Hexagonal Architecture Migration Status

**Target Architecture Spec:** [`docs/runtime-hexagonal-architecture-plan.md`](../../docs/runtime-hexagonal-architecture-plan.md)  
**Target Box Diagram:** [`assets/architecture/doe-zig-hexagonal-box-diagram.svg`](../../assets/architecture/doe-zig-hexagonal-box-diagram.svg)  
**Last Updated:** 2026-08-23

---

## Phase Checklist

### Phase 0: Baseline Freeze & Tracking
- [x] Create live migration status tracker (`HEXAGONAL_MIGRATION_TODO.md`)
- [x] Verify baseline tests, architecture gates, and proof pipeline

### Phase 1: Core Domain Contracts (`src/contracts/`)
- [x] Implement `src/contracts/prepared_operation.zig` (immutable execution units)
- [x] Implement `src/contracts/execution_report.zig` (standardized result & timing breakdown)
- [x] Implement `src/contracts/identity.zig` (typed cryptographic source/program/execution identities)
- [x] Implement `src/contracts/error.zig` (canonical error taxonomy)
- [x] Implement `src/contracts/exactness.zig` (oracle exactness and tolerance classes)
- [x] Implement `src/contracts/ownership.zig` (resource lifetime and memory ownership models)
- [x] Update `src/contracts/mod.zig` to expose new contracts

### Phase 2: Narrow Outbound Backend Ports (`src/backend/ports/`)
- [x] Implement `src/backend/ports/compute.zig` (`ComputePort` interface)
- [x] Implement `src/backend/ports/transfer.zig` (`TransferPort` interface)
- [x] Implement `src/backend/ports/queue.zig` (`QueuePort` interface)
- [x] Implement `src/backend/ports/readback.zig` (`ReadbackPort` interface)
- [x] Implement `src/backend/ports/telemetry.zig` (`TelemetryPort` interface)
- [x] Implement render, resource, surface, lifecycle, and spatial ports
- [x] Implement `src/backend/ports/mod.zig`

### Phase 3: Application Orchestration & Kernel-Dispatch Vertical Slice
- [x] Implement `src/app/request.zig` (application requests)
- [x] Implement `src/app/prepare.zig` (preparation from commands to immutable operations)
- [x] Implement `src/app/runner.zig` (driving execution through ports)
- [x] Implement `src/app/mod.zig`
- [x] Isolate provider construction in `src/composition/backend_factory.zig`
- [x] Update `source-layout.json` and architecture manifest

### Phase 4: Split the Backend Interface
- [x] Route compute, transfer, queue, readback, telemetry, render, resource,
      surface, and lifecycle behavior through narrow ports
- [x] Bind every provider directly to capability-specific ports at compile time
- [x] Make unsupported spatial execution fail explicitly instead of reporting
      synthetic success
- [x] Delete `BackendIface`, `BackendVTable`, and `backend_registry.zig`

### Phase 5: Establish the Real Inbound Routes
- [x] Route CLI canonical commands through `runtime/execution.zig`,
      `app/prepare.zig`, and `app/runner.zig`
- [x] Route plan-executor canonical commands through the same path
- [x] Remove the unconsumed `composition/cli.zig`, `native.zig`, `dropin.zig`,
      and `plan.zig` facades instead of treating package-root reachability as
      production use
- [x] Keep the native WebGPU object API and drop-in C ABI classified as a
      separate object/FFI execution surface; do not claim those object calls
      are canonical `Command` variants

### Phase 6: Extract the Evidence Plane
- [x] Implement `src/evidence/port.zig`
- [x] Modularize trace, receipt, replay, and oracle adapters under `src/evidence/`
- [x] Make evidence callbacks observational and infallible so they cannot veto
      provider selection or semantic execution
- [x] Feed observers the same prepared operation and execution report used by
      the production runner, including failures

### Phase 7: Deduplicate Runtime State
- [x] Consolidate execution routing through `src/runtime/execution.zig` and `src/app/`
- [x] Make Metal and Vulkan provider pipeline caches instance-owned; remove
      process-global session configuration and cross-provider telemetry shims
- [x] Route mutable pipeline-cache directories independently of immutable kernel roots
- [x] Move backend selection, ownership, and destruction into
      `src/composition/execution_session.zig`
- [x] Delete the old `src/backend/backend_runtime.zig` orchestration facade

### Phase 8: Migrate Remaining Commands
- [x] Map every canonical `Command` variant to exactly one borrowed read-only
      domain operation; provide an owned deep snapshot for retained work
- [x] Execute compute, transfer, render, resource, surface, and lifecycle
      operations through the application runner and narrow ports

### Phase 9: Finish Spatial & Integration Adapters
- [x] Implement `src/contracts/spatial_operation.zig` (`PreparedSpatialOperation`)
- [x] Implement `src/backend/ports/spatial.zig` (`SpatialPort`)
- [x] Route spatial port through `src/composition/backend_factory.zig`

### Phase 10: Remove Compatibility Facades and Complete Verification
- [x] Forbid runtime, CLI, plan, and package-root code from importing the broad
      backend interface
- [x] Verify import graph and layer isolation (586 source-bound module
      decisions frozen, 0 violations)
- [x] Pass the focused core, runtime, plan, benchmark-build, import-fence, and
      source-layout checks for this migration
- [x] Delete `BackendIface`/`BackendVTable` after Metal, Vulkan, D3D12, and
      delegate providers expose direct port bundles
- [x] Re-run the complete blocking Zig gate set after facade deletion
- [x] Pass physical Apple Metal compute and staged-write exactness checks
- [ ] Pass physical AMD Vulkan, Windows D3D12, and Fawn browser qualification
      on their target hosts

## Current truthful status

The production CLI, plan executor, output oracle, and Metal correctness
benchmarks now create a composition-owned `ExecutionSession`. Runtime borrows
only a `PortBundle`; it no longer imports backend policy, registry, or concrete
providers. `BackendRuntime`, `BackendIface`, `BackendVTable`, and the backend
registry are deleted. Providers instantiate capability-specific port vtables
at compile time, while `composition/backend_factory.zig` alone selects and owns
the physical provider. All canonical command variants are prepared once,
executed by one application runner, and observed by the evidence plane without
granting evidence code semantic authority.

The structural migration is complete. Physical qualification is deliberately
tracked separately: Apple Metal exact-output and exact-byte checks pass on the
current host; AMD Vulkan, Windows D3D12, and Fawn browser promotion still
require their target hardware and release evidence. Those external gates are
not conclusions implied by an import graph or mock test.
