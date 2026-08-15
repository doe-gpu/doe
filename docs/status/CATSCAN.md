# CATSCAN: Status

Parent: [Documentation](../CATSCAN.md)

## Target

Route readers to the current promoted boundary, active blockers, and machine-owned ground truth for each Doe domain.

## Authority

- Owns concise live status front doors and append-only historical routing.
- Does not own strategy, architecture, contract definitions, or copied artifact inventories.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Status policy: [`README.md`](README.md).
- Current public evidence: [`../../reports/claim-index.json`](../../reports/claim-index.json).

Outputs:
- Topical live shards and dated archives linked from [`../status.md`](../status.md).

## Invariants

- Live shards state boundaries and blockers without embedding mutable counts.
- New state enters the relevant live shard; history remains in `archive/`.
- Diagnostic, claimable, scaffolded, and unsupported states remain distinct.

## Acceptance

- Status links resolve and public claims remain artifact-backed.
- Evidence: [`../../bench/tests/test_doc_link_coverage.py`](../../bench/tests/test_doc_link_coverage.py).

## Non-goals

- A chronological engineering diary or a second strategy document.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
