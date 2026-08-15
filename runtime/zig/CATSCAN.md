# CATSCAN: Zig runtime

Parent: [Runtime](../CATSCAN.md)

## Target

Provide Doe's deterministic native WebGPU runtime, compiler, and backend execution in a maintainable Zig implementation.

## Authority

- Owns native API behavior, queues, resources, lifecycle, compiler integration, Metal, Vulkan, D3D12, drop-in, and embedded execution.
- Does not own public package resolution, claim promotion, or external workload truth.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Runtime contract: [`README.md`](README.md).
- Source layout policy: [`source-layout.json`](source-layout.json).

Outputs:
- Native libraries, tools, backend artifacts, and typed runtime diagnostics.

## Invariants

- Unsupported capabilities fail with original typed causes and no hidden fallback.
- Backend behavior is real or rejected; fake execution and synthetic state are forbidden.
- Resource ownership, synchronization, completion, and readback remain explicit.

## Acceptance

- Core and full runtime contracts pass through the canonical Zig build.
- Evidence: [`build.zig`](build.zig).

## Non-goals

- Reimplementing package policy, benchmark policy, or application-level orchestration.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
