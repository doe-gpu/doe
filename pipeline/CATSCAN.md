# CATSCAN: Pipeline

Parent: [Doe](../CATSCAN.md)

## Target

Normalize upstream intelligence, traces, and proofs into deterministic inputs and evidence consumed by Doe components.

## Authority

- Owns mining, normalization, trace/replay, proof extraction, and pipeline-specific contracts.
- Does not own runtime execution, product claims, or benchmark promotion.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Stage order: [`../docs/process.md`](../docs/process.md).
- Repository goals: [`../GOALS.md`](../GOALS.md).

Outputs:
- Normalized quirks, trace artifacts, proof artifacts, and reproducible pipeline receipts.

## Invariants

- Mine, Normalize, Verify, and Bind boundaries remain explicit.
- Generated artifacts retain source provenance and deterministic regeneration paths.
- Pipeline evidence cannot substitute for physical execution evidence.

## Acceptance

- Each child pipeline owns focused tests and evidence linked by its charter.
- Evidence: [`agent/README.md`](agent/README.md).

## Non-goals

- A second runtime, benchmark harness, or autonomous product roadmap.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
