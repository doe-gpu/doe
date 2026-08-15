# CATSCAN: External application portfolio

Parent: [Benchmark and evidence system](../CATSCAN.md)

## Target

Turn pinned real applications into governed compatibility evidence, minimized failures, and eligible release dependencies.

## Authority

- Owns external source preparation, minimal provider substitution, application oracles, reviewed failures, and promotion harnesses.
- Does not own upstream projects, customer relationships, runtime strategy, or promotion by narrative.

## Scope

- Includes files beneath this directory except child-chartered components, which narrow this authority.

## Contracts

Inputs:
- Portfolio law: [`../../docs/runtime-ownership-decision.md`](../../docs/runtime-ownership-decision.md).
- Registry governance: [`../../docs/ecosystem.md`](../../docs/ecosystem.md).

Outputs:
- Reproducible harnesses, preparation and reproduction receipts, failure records, and promotion candidates.

## Invariants

- Upstream source, patches, inputs, provider, hardware, and oracle remain pinned.
- Each runtime-ownership candidate retains incumbent, governed-wrapper, and Doe lanes.
- Diagnostic applications do not silently become release blockers.

## Acceptance

- Promoted harnesses satisfy the external-project release gate and ownership attribution.
- Evidence: [`../gates/external_project_release_gate.py`](../gates/external_project_release_gate.py).

## Non-goals

- Treating an external project as a customer, adopter, or Doe-owned roadmap without evidence.

## Freedom

Any mechanism is permitted if it preserves these boundaries and passes the acceptance evidence.
