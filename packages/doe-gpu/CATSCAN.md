# CATSCAN: doe-gpu

Parent: [Packages](../CATSCAN.md)

## Target

Let controlled JavaScript applications select an explicit provider, execute supported GPU work, validate output, and receive attributable runtime identity and receipts.

## Authority

- Owns public JavaScript and CLI exports, provider acquisition, governed callback and unchanged-process exact-output execution, global installation and restoration, package diagnostics, and Program Bundle validation.
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
- Bounded or cancelled governed processes terminate at the declared platform
  scope, and receipts never overstate descendant cleanup.
- Declared runtime files are hash-bound without being mislabeled as a complete
  or isolated dependency closure.

## Acceptance

- Package contract, smoke, CLI, and integration suites exercise the shipped surface.
- Evidence: [`test/run-contracts.js`](test/run-contracts.js).

## Non-goals

- Arbitrary npm WebGPU compatibility or evidence of Chromium runtime replacement.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
