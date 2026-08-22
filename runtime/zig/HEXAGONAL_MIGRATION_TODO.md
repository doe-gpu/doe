# Doe Zig Hexagonal Architecture Migration Status

**Target Architecture Spec:** [`docs/runtime-hexagonal-architecture-plan.md`](../../docs/runtime-hexagonal-architecture-plan.md)  
**Target Box Diagram:** [`assets/architecture/doe-zig-hexagonal-box-diagram.svg`](../../assets/architecture/doe-zig-hexagonal-box-diagram.svg)  
**Last Updated:** 2026-08-22

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
- [x] Implement `src/backend/ports/mod.zig`

### Phase 3: Application Orchestration & Kernel-Dispatch Vertical Slice
- [x] Implement `src/app/request.zig` (application requests)
- [x] Implement `src/app/prepare.zig` (preparation from commands to immutable operations)
- [x] Implement `src/app/runner.zig` (driving execution through ports)
- [x] Implement `src/app/mod.zig`
- [x] Bridge `backend/backend_iface.zig` with `ComputePort`
- [x] Update `source-layout.json` and architecture manifest

### Phase 4: Split the Backend Interface
- [x] Migrate `ComputePort` across Metal, Vulkan, and D3D12 via `BackendIface.asComputePort()`
- [x] Migrate `TransferPort` via `BackendIface.asTransferPort()`
- [x] Migrate `QueuePort` via `BackendIface.asQueuePort()`
- [x] Migrate `ReadbackPort` via `BackendIface.asReadbackPort()`
- [x] Migrate `TelemetryPort` via `BackendIface.asTelemetryPort()`

### Phase 5: Extract Application Orchestration Across All Inbound Adapters
- [x] Unify CLI orchestration through `src/composition/cli.zig` and `src/app/`
- [x] Unify native WebGPU object API through `src/composition/native.zig` and `src/app/`
- [x] Unify drop-in C ABI through `src/composition/dropin.zig` and `src/app/`
- [x] Unify plan executor through `src/composition/plan.zig` and `src/app/`

### Phase 6: Extract the Evidence Plane
- [x] Implement `src/evidence/port.zig`
- [x] Modularize trace, receipt, replay, and oracle adapters under `src/evidence/`

### Phase 7: Deduplicate Runtime State
- [x] Consolidate execution routing through `src/runtime/execution.zig` and `src/app/`
- [x] Retain centralized pipeline caches and resource state without duplication

### Phase 8: Migrate Remaining Commands
- [x] Implement `src/contracts/render_command.zig` (`PreparedRenderPassOperation`, `PreparedPipelineOperation`)
- [x] Implement `src/backend/ports/render.zig` (`RenderPort`)

### Phase 9: Finish Spatial & Integration Adapters
- [x] Implement `src/contracts/spatial_operation.zig` (`PreparedSpatialOperation`)
- [x] Implement `src/backend/ports/spatial.zig` (`SpatialPort`)
- [x] Route spatial port through `src/composition/backend_factory.zig`

### Phase 10: Complete Architecture Verification
- [x] Verify import graph and layer isolation (585 module decisions frozen, 0 violations)
- [x] 100% test passing across `test-core`, `test-wgsl`, `line-limits`, and `import-fence`
