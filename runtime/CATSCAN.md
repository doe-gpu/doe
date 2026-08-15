# CATSCAN: Runtime

Parent: [Doe](../CATSCAN.md)

## Target

Own native execution and integration surfaces that implement Doe's explicit provider, lifecycle, and backend contracts.

## Authority

- Owns native runtime implementations and bounded host integration bridges.
- Does not own package UX, benchmark verdicts, browser policy, or application orchestration.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Runtime architecture: [`../docs/architecture.md`](../docs/architecture.md).
- Support matrix: [`../docs/doe-support-matrix.md`](../docs/doe-support-matrix.md).

Outputs:
- Native libraries, compiler artifacts, backend execution, and integration bridges.

## Invariants

- Runtime behavior is native or explicitly unsupported; synthetic runtime state is forbidden.
- Provider, backend, lifecycle, and failure state remain observable.
- Compatibility bridges do not silently become canonical implementations.

## Acceptance

- Native surfaces remain within the declared architecture and import boundaries.
- Evidence: [`zig/reports/architecture/reachability-views.json`](zig/reports/architecture/reachability-views.json).

## Non-goals

- Owning evidence policy, external application behavior, or browser-wide responsibilities.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
