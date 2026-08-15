# CATSCAN: Browser

Parent: [Doe](../CATSCAN.md)

## Target

Govern browser-hosted Doe execution as an independently admitted product surface separate from package and native claims.

## Authority

- Owns browser integration boundaries and routing to browser-specific contracts and evidence.
- Does not own Chromium-wide policy, package wrappers, native runtime semantics, or browser claims without a released artifact.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Browser boundary: [`../docs/browser-lane.md`](../docs/browser-lane.md).
- Runtime surface law: [`../docs/runtime-surface-boundary.md`](../docs/runtime-surface-boundary.md).

Outputs:
- Governed browser integration components and separately classified browser evidence.

## Invariants

- Browser evidence never inherits package or native claim status.
- The incumbent browser wrapper is not represented as Doe beneath `navigator.gpu`.
- Forced-provider identity and fallback state remain explicit.

## Acceptance

- Browser work routes through the Chromium acceptance and release contracts.
- Evidence: [`chromium/plan.md`](chromium/plan.md).

## Non-goals

- Browser automation, Chromium-wide replacement, or generic browser benchmark claims.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
