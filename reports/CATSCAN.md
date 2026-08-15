# CATSCAN: Published reports

Parent: [Doe](../CATSCAN.md)

## Target

Publish stable, reviewable evidence summaries whose claims remain bound to governed raw artifacts.

## Authority

- Owns reviewed claim indexes, ecosystem summaries, parity receipts, and retained benchmark reports intended for review.
- Does not own raw run generation, strategy, support policy, or unreviewed diagnostic promotion.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Claim boundary: [`../docs/public-claim-boundary.md`](../docs/public-claim-boundary.md).
- Benchmark evidence law: [`../bench/README.md`](../bench/README.md).

Outputs:
- Public claim index: [`claim-index.json`](claim-index.json).
- Stable reviewed reports linked to their source evidence.

## Invariants

- Claim-indexed, diagnostic, status-only, and scaffolded evidence never conflate.
- Reports retain workload, provider, hardware, oracle, and source-artifact identity.
- A summary cannot strengthen the claim class of its inputs.

## Acceptance

- Claim-index entries and referenced sidecars pass semantic admission.
- Evidence: [`../bench/gates/claim_index_gate.py`](../bench/gates/claim_index_gate.py).

## Non-goals

- Serving as an ungoverned dump of temporary runs or hand-edited current status.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
