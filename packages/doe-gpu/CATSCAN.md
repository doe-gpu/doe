# CATSCAN: doe-gpu

Parent: [Packages](../CATSCAN.md)

## Target

Let JavaScript applications select providers, execute supported work, and validate attributable results.

## Authority

- Owns package exports, providers, governed execution, global restoration,
  diagnostics, bundle validation, and fixed-shape compute-program lifetime.
- Does not own browser `navigator.gpu`, native backend implementation, or undeclared fallback.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Public API contract: [`README.md`](README.md).
- Runtime scope: [`../../docs/doe-gpu-node-runtime-scope.md`](../../docs/doe-gpu-node-runtime-scope.md).

Outputs:
- Host-aware package APIs and receipts backed by an explicitly selected provider.

## Invariants

- Provider attempts, effective identity, and failure causes remain visible.
- `close()` restores every global descriptor changed by the session.
- Unsupported tuples fail explicitly and never select an undeclared provider.
- DoeProof receipts never assign DoeRuntime ownership credit.
- Programs own private resources and immutable declarations; updates retain
  identical contracts, invalidate old recordings, and roll back failed preparation.
- Bounded or cancelled processes terminate at the declared platform scope;
  receipts never overstate descendant cleanup.
- Declared runtime files are hash-bound without being mislabeled as a complete
  or isolated dependency closure.
- Node permission receipts expose the effective read allowlist and required
  loader-worker exception without claiming an operating-system sandbox.

## Acceptance

- Package contract, smoke, CLI, and integration suites exercise the shipped surface.
- Evidence: [`test/run-contracts.js`](test/run-contracts.js).

## Non-goals

- Arbitrary npm WebGPU compatibility or evidence of Chromium runtime replacement.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
